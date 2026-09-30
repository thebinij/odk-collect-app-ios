import Combine
import SwiftUI
import XCTest
@testable import ODKWebEngine

/// End-to-end tests against the two real XLSForm-compiled forms that surfaced the
/// "question not visible" bug report (`grievance.xlsx` / `disbursement_verify.xlsx`,
/// converted to XML via pyxform). These drive the exact same `EnketoFormView`/
/// `EnketoFormState` pipeline the app uses — filling in every question a real user
/// would encounter (including the conditional branches), requesting a submission, and
/// checking the serialized instance XML — standing in for the interactive simulator
/// run-through that isn't possible in this environment (no Accessibility/UI-automation
/// access to drive the Simulator's screen). Also covers save-draft-then-resume, since
/// that was explicitly asked for alongside "answer everything and send".
@MainActor
final class RealFormEndToEndTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []
    private var window: UIWindow?

    override func tearDown() {
        cancellables.removeAll()
        window?.rootViewController = nil
        window?.isHidden = true
        window = nil
        let settled = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        super.tearDown()
    }

    // MARK: - Harness (same pattern as EnketoEngineIntegrationTests)

    private func loadForm(_ xformXML: String, instanceXML: String? = nil) -> EnketoFormState {
        let state = EnketoFormState()
        let hosting = UIHostingController(rootView: EnketoFormView(xformXML: xformXML, instanceXML: instanceXML, state: state))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        self.window = window
        hosting.view.layoutIfNeeded()

        let ready = expectation(description: "formReady and questions loaded")
        state.$questions.dropFirst().first().sink { _ in ready.fulfill() }.store(in: &cancellables)
        wait(for: [ready], timeout: 10)

        XCTAssertNil(state.loadError)
        XCTAssertTrue(state.isFormReady)
        return state
    }

    private func waitForQuestions(_ state: EnketoFormState, until predicate: @escaping ([Question]) -> Bool, after action: () -> Void) {
        if predicate(state.questions) { return }
        let satisfied = expectation(description: "questions satisfy predicate")
        var fulfilled = false
        state.$questions
            .sink { questions in
                if !fulfilled && predicate(questions) {
                    fulfilled = true
                    satisfied.fulfill()
                }
            }
            .store(in: &cancellables)
        action()
        wait(for: [satisfied], timeout: 10)
    }

    private func waitForSubmission(_ state: EnketoFormState, after action: () -> Void) -> String? {
        let done = expectation(description: "submission or validation failure")
        var xml: String?
        var fulfilled = false
        state.$submissionXML
            .sink { value in
                guard !fulfilled, let value else { return }
                fulfilled = true
                xml = value
                done.fulfill()
            }
            .store(in: &cancellables)
        state.$validationFailed
            .sink { failed in
                guard !fulfilled, failed else { return }
                fulfilled = true
                done.fulfill()
            }
            .store(in: &cancellables)
        action()
        wait(for: [done], timeout: 10)
        return xml
    }

    private func waitForDraft(_ state: EnketoFormState, after action: () -> Void) -> String? {
        let done = expectation(description: "draft")
        var xml: String?
        var fulfilled = false
        state.$draftXML
            .sink { value in
                guard !fulfilled, let value else { return }
                fulfilled = true
                xml = value
                done.fulfill()
            }
            .store(in: &cancellables)
        action()
        wait(for: [done], timeout: 10)
        return xml
    }

    private func question(_ state: EnketoFormState, _ ref: String) -> Question? {
        state.questions.first { $0.ref == ref }
    }

    // MARK: - grievance.xml — "someone_else, not confidential" branch (every field live)

    func testGrievanceFormSubmitsSuccessfullyWhenReportingOnBehalfOfSomeoneElse() {
        let state = loadForm(Self.grievanceForm)

        // XLSForm's `today` type (`jr:preload="date" jr:preloadParams="today"`)
        // compiles to a preload-only field with *no* body `<input>` at all — it
        // lands in enketo-core's auto-generated `#or-preload-items` bucket,
        // wrapped in `.calculation` rather than `.question`, exactly like
        // `meta/instanceID`. That's correct, matching real ODK Collect: `today`
        // (like `start`/`end`/`deviceid`) is silent metadata, never shown as a
        // question — so it's correctly absent from `state.questions` entirely.
        // What must still hold is that the model actually preloaded a value, so
        // `required="true()"` doesn't block submission of an invisible field the
        // native UI has no way to let the user fix.
        XCTAssertNil(question(state, "/data/date_lodged"), "today-type fields are silent metadata, same as meta/instanceID — never a visible question")

        // The whole `grievance_details` group is one field-list; every member
        // shares its ref, and irrelevant members are still *reported* (just
        // flagged) — filtering to what's currently answerable is
        // `QuestionFlowEngine`'s job, not the bridge's.
        for ref in [
            "/data/grievance_details/is_own_grievance",
            "/data/grievance_details/is_confidential",
            "/data/grievance_details/complainant_name",
            "/data/grievance_details/complainant_phone",
            "/data/grievance_details/complainant_email",
            "/data/grievance_details/description"
        ] {
            XCTAssertEqual(question(state, ref)?.fieldListGroupRef, "/data/grievance_details", "\(ref) should be clustered into the group page")
        }
        XCTAssertEqual(question(state, "/data/grievance_details/is_confidential")?.relevant, false, "not relevant until is_own_grievance = someone_else")
        XCTAssertEqual(question(state, "/data/grievance_details/complainant_name")?.relevant, false)

        // Answer is_own_grievance live — is_confidential must become relevant
        // immediately, in the same group, without any page transition.
        waitForQuestions(state, until: { $0.first(where: { $0.ref == "/data/grievance_details/is_confidential" })?.relevant == true }) {
            state.setValue(ref: "/data/grievance_details/is_own_grievance", index: 0, value: "someone_else", typeXml: "string")
        }

        // Answer is_confidential = "no" — the three complainant_* fields must
        // become relevant live too, still the same group.
        waitForQuestions(state, until: { $0.first(where: { $0.ref == "/data/grievance_details/complainant_name" })?.relevant == true }) {
            state.setValue(ref: "/data/grievance_details/is_confidential", index: 0, value: "no", typeXml: "string")
        }
        XCTAssertEqual(question(state, "/data/grievance_details/complainant_phone")?.relevant, true)
        XCTAssertEqual(question(state, "/data/grievance_details/complainant_email")?.relevant, true)

        state.setValue(ref: "/data/grievance_details/complainant_name", index: 0, value: "Sita Sharma", typeXml: "string")
        state.setValue(ref: "/data/grievance_details/complainant_phone", index: 0, value: "9800000000", typeXml: "string")
        state.setValue(ref: "/data/grievance_details/complainant_email", index: 0, value: "sita@example.com", typeXml: "string")
        waitForQuestions(state, until: { $0.first(where: { $0.ref == "/data/grievance_details/description" })?.value == "The road near the school is blocked." }) {
            state.setValue(ref: "/data/grievance_details/description", index: 0, value: "The road near the school is blocked.", typeXml: "string")
        }

        let xml = waitForSubmission(state) { state.requestSubmission() }
        XCTAssertFalse(state.validationFailed, "every required field was answered — submission must not be rejected")
        XCTAssertNotNil(xml, "expected serialized submission XML")
        XCTAssertTrue(xml?.contains("<is_own_grievance>someone_else</is_own_grievance>") ?? false)
        XCTAssertTrue(xml?.contains("<is_confidential>no</is_confidential>") ?? false)
        XCTAssertTrue(xml?.contains("<complainant_name>Sita Sharma</complainant_name>") ?? false)
        XCTAssertTrue(xml?.contains("<description>The road near the school is blocked.</description>") ?? false)
        // Confirms the "today" preload actually wrote a value to the model even
        // though it's never exposed as a question — an empty `required` field
        // the user has no way to see or fix would otherwise silently block
        // every submission of this form.
        XCTAssertFalse(xml?.contains("<date_lodged/>") ?? true, "date_lodged must have been preloaded, not left empty")
        XCTAssertTrue(xml?.range(of: #"<date_lodged>\d{4}-\d{2}-\d{2}</date_lodged>"#, options: .regularExpression) != nil, "expected an ISO date preloaded into date_lodged")
    }

    // MARK: - grievance.xml — "mine" branch (conditional fields must stay excluded)

    func testGrievanceFormSubmitsSuccessfullyWhenReportingOnesOwnGrievanceWithoutTouchingConditionalFields() {
        let state = loadForm(Self.grievanceForm)

        waitForQuestions(state, until: { $0.first(where: { $0.ref == "/data/grievance_details/is_own_grievance" })?.value == "mine" }) {
            state.setValue(ref: "/data/grievance_details/is_own_grievance", index: 0, value: "mine", typeXml: "string")
        }
        // is_confidential/complainant_* must stay irrelevant — answering "mine"
        // never asks who the confidential identity belongs to.
        XCTAssertEqual(question(state, "/data/grievance_details/is_confidential")?.relevant, false)
        XCTAssertEqual(question(state, "/data/grievance_details/complainant_name")?.relevant, false)

        waitForQuestions(state, until: { $0.first(where: { $0.ref == "/data/grievance_details/description" })?.value == "Streetlights have been out for a week." }) {
            state.setValue(ref: "/data/grievance_details/description", index: 0, value: "Streetlights have been out for a week.", typeXml: "string")
        }

        let xml = waitForSubmission(state) { state.requestSubmission() }
        XCTAssertFalse(state.validationFailed, "is_confidential/complainant_* are irrelevant, so their emptiness must not block submission")
        XCTAssertNotNil(xml)
        XCTAssertTrue(xml?.contains("<is_own_grievance>mine</is_own_grievance>") ?? false)
        XCTAssertTrue(xml?.contains("<description>Streetlights have been out for a week.</description>") ?? false)
    }

    // MARK: - disbursement_verify.xml — "not received" branch (optional upload stays skippable)

    func testDisbursementVerifyFormSubmitsSuccessfullyWithoutTheOptionalProofWhenNotReceived() {
        let state = loadForm(Self.disbursementVerifyForm)
        XCTAssertEqual(question(state, "/data/proof")?.relevant, false, "not received yet, so no proof to attach")

        waitForQuestions(state, until: { $0.first(where: { $0.ref == "/data/received_status" })?.value == "not_received" }) {
            state.setValue(ref: "/data/received_status", index: 0, value: "not_received", typeXml: "string")
        }
        XCTAssertEqual(question(state, "/data/proof")?.relevant, false)

        let xml = waitForSubmission(state) { state.requestSubmission() }
        XCTAssertFalse(state.validationFailed, "proof is optional and irrelevant; remarks is optional — nothing else should block this")
        XCTAssertNotNil(xml)
        XCTAssertTrue(xml?.contains("<received_status>not_received</received_status>") ?? false)
    }

    func testDisbursementVerifyFormMakesProofRelevantOnceReceived() {
        let state = loadForm(Self.disbursementVerifyForm)
        waitForQuestions(state, until: { $0.first(where: { $0.ref == "/data/proof" })?.relevant == true }) {
            state.setValue(ref: "/data/received_status", index: 0, value: "received", typeXml: "string")
        }
        XCTAssertEqual(question(state, "/data/proof")?.relevant, true)
    }

    // MARK: - Save draft, then resume from it (as an alternative to sending)

    func testSavingADraftMidGrievanceFormAndResumingPrefillsExactlyWhatWasEntered() {
        let state = loadForm(Self.grievanceForm)
        waitForQuestions(state, until: { $0.first(where: { $0.ref == "/data/grievance_details/is_own_grievance" })?.value == "someone_else" }) {
            state.setValue(ref: "/data/grievance_details/is_own_grievance", index: 0, value: "someone_else", typeXml: "string")
        }
        // Deliberately stop here — is_confidential and everything after it are
        // left unanswered, exactly like a user backing out partway through.
        let draftXML = waitForDraft(state) { state.requestDraftSave() }
        XCTAssertNotNil(draftXML, "draft save must not require the form to be valid/complete")

        let resumed = loadForm(Self.grievanceForm, instanceXML: draftXML)
        XCTAssertEqual(question(resumed, "/data/grievance_details/is_own_grievance")?.value, "someone_else")
        XCTAssertEqual(question(resumed, "/data/grievance_details/is_confidential")?.relevant, true, "resuming must replay the same relevant cascade, not just the raw values")
        XCTAssertEqual(question(resumed, "/data/grievance_details/is_confidential")?.value, "")
    }
}

// MARK: - Fixtures
//
// Verbatim output of `pyxform.xls2xform.xls2xform_convert(..., validate: false)`
// against the actual `grievance.xlsx` / `disbursement_verify.xlsx` sample forms
// reported against — not hand-written approximations — so these tests exercise
// exactly the DOM shape that triggered the bug (secondary-instance itemsets for
// every choice list, including fully static ones, nested inside a `field-list`
// group).
private extension RealFormEndToEndTests {
    static let grievanceForm = Fixtures.load("grievanceForm")

    static let disbursementVerifyForm = Fixtures.load("disbursementVerifyForm")
}
