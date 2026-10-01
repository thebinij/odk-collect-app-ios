import Combine
import SwiftUI
import XCTest
@testable import ODKWebEngine

/// Drives the real `EnketoFormView`/`EnketoFormState` (the exact same code path the
/// app uses — not a hand-rolled duplicate) against real XForm fixtures, through a live
/// `WKWebView` hosted in an actual view hierarchy. These are regression tests for bugs
/// that only show up against enketo-core's real rendered DOM — every one here was
/// caught by, and reproduces, an actual reported issue.
///
/// Each `WKWebView` costs a real WebContent process; instantiating too many of them
/// back-to-back in one test run exhausts that pool (observed as a
/// `WebProcessProxy::didClose` crash partway through a full run). So related
/// assertions are grouped into one test per loaded form/state rather than one test per
/// assertion — keep that pattern when adding more.
@MainActor
final class EnketoEngineIntegrationTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []
    private var window: UIWindow?

    override func tearDown() {
        cancellables.removeAll()
        window?.rootViewController = nil
        window?.isHidden = true
        window = nil
        // Give the outgoing WebContent process a beat to actually terminate before
        // the next test's `loadForm` spins up a new one.
        let settled = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        super.tearDown()
    }

    // MARK: - Harness

    private func loadForm(_ xformXML: String, instanceXML: String? = nil) -> EnketoFormState {
        let state = EnketoFormState()
        let hosting = UIHostingController(rootView: EnketoFormView(xformXML: xformXML, instanceXML: instanceXML, state: state))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        self.window = window
        hosting.view.layoutIfNeeded()

        // `isFormReady` flips to `true` synchronously, *before* the `requestQuestions()`
        // call it triggers has actually round-tripped through the JS bridge — waiting
        // on it alone is a race (state.questions would still be the initial `[]`).
        // Wait for the first real `questions` emission instead.
        let ready = expectation(description: "formReady and questions loaded")
        state.$questions
            .dropFirst()
            .first()
            .sink { _ in ready.fulfill() }
            .store(in: &cancellables)
        wait(for: [ready], timeout: 10)

        XCTAssertNil(state.loadError)
        XCTAssertTrue(state.isFormReady)
        return state
    }

    /// Runs `action`, then waits for the next `questions` refresh it triggers
    /// (`setValue`/`addRepeatInstance`/`removeRepeatInstance` all end in one).
    private func waitForQuestionsUpdate(_ state: EnketoFormState, after action: () -> Void) {
        let updated = expectation(description: "questions updated")
        var fulfilled = false
        state.$questions
            .dropFirst()
            .sink { _ in
                if !fulfilled {
                    fulfilled = true
                    updated.fulfill()
                }
            }
            .store(in: &cancellables)
        action()
        wait(for: [updated], timeout: 10)
    }

    /// Like `waitForQuestionsUpdate`, but waits until `state.questions` actually
    /// satisfies `predicate` rather than merely for "the next emission" — a
    /// `validateQuestion` call posts its own trailing `getQuestions()` refresh
    /// from inside a `.then()` callback, so a *prior* validation's refresh can
    /// still be in flight when a later action's "wait for the next update"
    /// subscription starts; under load that stale emission can arrive first and
    /// satisfy it with pre-action data. Waiting on the actual condition sidesteps
    /// that ordering race entirely.
    private func waitForQuestions(_ state: EnketoFormState, until predicate: @escaping ([Question]) -> Bool, after action: () -> Void) {
        if predicate(state.questions) { return }
        let satisfied = expectation(description: "questions satisfy predicate")
        var fulfilled = false
        // Subscribing before running `action` means even a stale, already-in-flight
        // emission (see above) gets checked against `predicate` and — since it
        // reflects pre-action data — correctly fails to satisfy it and is ignored,
        // rather than prematurely fulfilling the expectation.
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

    /// The `fulfilled` guard (and matching one in `waitForGroupValidation` below)
    /// isn't optional bookkeeping: this subscription outlives the call — it's
    /// only ever cancelled in bulk by `tearDown`'s `cancellables.removeAll()` —
    /// so if this helper is used more than once in the same test, an *earlier*
    /// call's still-live subscription also receives every *later* call's
    /// emission and would otherwise call `.fulfill()` again on an expectation
    /// whose `wait()` has already returned, which XCTest treats as a crash
    /// ("API violation - multiple calls made to fulfill"), not a harmless no-op.
    private func waitForValidation(_ state: EnketoFormState, after action: () -> Void) -> QuestionValidationResult? {
        let validated = expectation(description: "validated")
        var result: QuestionValidationResult?
        var fulfilled = false
        state.$lastValidationResult
            .dropFirst(state.lastValidationResult == nil ? 0 : 1)
            .compactMap { $0 }
            .sink { value in
                guard !fulfilled else { return }
                fulfilled = true
                result = value
                validated.fulfill()
            }
            .store(in: &cancellables)
        action()
        wait(for: [validated], timeout: 10)
        return result
    }

    /// `.dropFirst()` matters here specifically because this helper gets called
    /// more than once per test (one page can be validated, fixed up, and
    /// re-validated) — without it, a second call's fresh subscription would
    /// immediately replay the *first* call's already-published result (Combine
    /// re-sends a `@Published` property's current value to every new
    /// subscriber) and resolve before `action` even runs. The `fulfilled` guard
    /// is equally required, not just tidy: this subscription is never cancelled
    /// individually (only in bulk by `tearDown`), so on a *second* call the
    /// first call's still-live subscription also observes the second action's
    /// emission and would otherwise re-`.fulfill()` its own, already-completed
    /// expectation — which XCTest raises as a crash, not a no-op.
    private func waitForGroupValidation(_ state: EnketoFormState, after action: () -> Void) -> GroupValidationResult? {
        let validated = expectation(description: "group validated")
        var result: GroupValidationResult?
        var fulfilled = false
        state.$lastGroupValidationResult
            .dropFirst(state.lastGroupValidationResult == nil ? 0 : 1)
            .compactMap { $0 }
            .sink { value in
                guard !fulfilled else { return }
                fulfilled = true
                result = value
                validated.fulfill()
            }
            .store(in: &cancellables)
        action()
        wait(for: [validated], timeout: 10)
        return result
    }

    private func question(_ state: EnketoFormState, _ ref: String) -> Question? {
        state.questions.first { $0.ref == ref }
    }

    // MARK: - Basic sanity + required validation (one form, one webview)

    func testLinearFormReportsQuestionsAndValidatesRequiredFields() {
        let state = loadForm(Self.linearForm)
        XCTAssertEqual(state.questions.map(\.ref), ["/data/name", "/data/age"])
        XCTAssertEqual(question(state, "/data/name")?.kind, .string)
        XCTAssertEqual(question(state, "/data/age")?.kind, .int)

        let result = waitForValidation(state) {
            state.validateQuestion(ref: "/data/name", index: 0)
        }
        XCTAssertEqual(result?.valid, false, "required and empty")
        XCTAssertNotNil(result?.message)

        // Regression: a stuck-disabled "Next" bug traced back to the *native*
        // one-question flow only resetting its busy/loading flag when a
        // validation result's uid matched the currently displayed question —
        // any other result (stale, or for a different question) silently fell
        // through and left that flag permanently true. This can't be exercised
        // through `QuestionFlowView` itself (its busy flag is private SwiftUI
        // `@State`, and there's no UI-automation access in this environment to
        // drive it), but the layer beneath it — does re-validating after
        // correcting the value actually report valid? — is exactly what would
        // silently break if `EnketoFormState`/bridge.js stopped re-evaluating
        // constraints on a fresh value, so it's covered here.
        let corrected = waitForValidation(state) {
            state.setValue(ref: "/data/name", index: 0, value: "Ada", typeXml: "string")
            state.validateQuestion(ref: "/data/name", index: 0)
        }
        XCTAssertEqual(corrected?.valid, true, "now non-empty — must report valid, not keep reporting the earlier failure")
        XCTAssertNil(corrected?.message)
    }

    func testResumingWithInstanceXMLPrefillsAnswers() {
        let state = loadForm(Self.linearForm, instanceXML: "<data><name>Ada</name><age>30</age></data>")
        XCTAssertEqual(question(state, "/data/name")?.value, "Ada")
        XCTAssertEqual(question(state, "/data/age")?.value, "30")
    }

    // MARK: - Meta / hidden exclusion (regression: "hidden question shown as a real question")

    func testMetaFieldIsFlaggedHiddenEvenWhenExplicitlyGivenABodyBinding() {
        // The bridge reports every body-bound field, however bookkeeping-only it is —
        // filtering out anything `hidden` (or irrelevant) is the native layer's job,
        // done by `QuestionFlowEngine`/the read-only summary views, never the bridge
        // itself. So a meta/* field stays IN `state.questions`, just flagged.
        let state = loadForm(Self.metaFieldForm)
        XCTAssertEqual(question(state, "/data/meta/instanceName")?.hidden, true, "meta/* is always bookkeeping, never a real question")
        XCTAssertEqual(state.questions.map(\.ref), ["/data/name", "/data/meta/instanceName"])
    }

    func testAppearanceHiddenFieldIsFlaggedAndExcludedFromNavigation() {
        let state = loadForm(Self.appearanceHiddenForm)
        let secret = question(state, "/data/secret")
        XCTAssertEqual(secret?.hidden, true)
        XCTAssertEqual(secret?.relevant, true, "hidden is independent of relevant")
    }

    // MARK: - Group-inherited relevance (regression: "required question with nothing to fill in")

    func testQuestionInsideAnIrrelevantGroupInheritsThatIrrelevance() {
        let state = loadForm(Self.groupRelevantForm)
        XCTAssertEqual(question(state, "/data/g1/a")?.relevant, false, "the group itself is not yet relevant")

        waitForQuestionsUpdate(state) {
            state.setValue(ref: "/data/gate", index: 0, value: "yes", typeXml: "string")
        }
        XCTAssertEqual(question(state, "/data/g1/a")?.relevant, true, "gate answered — group, and its child, become relevant")
    }

    // MARK: - Cascading (dynamic itemset) selects (regression: "select with zero options")

    func testCascadingSelectPopulatesFilteredOptionsOnceItsParentIsAnswered() {
        let state = loadForm(Self.cascadingSelectForm)
        XCTAssertEqual(question(state, "/data/city")?.kind, .select1)
        XCTAssertEqual(question(state, "/data/city")?.options, [], "no country chosen yet")

        waitForQuestionsUpdate(state) {
            state.setValue(ref: "/data/country", index: 0, value: "np", typeXml: "string")
        }
        let options = Set(question(state, "/data/city")?.options.map(\.value) ?? [])
        XCTAssertEqual(options, ["kathmandu", "pokhara"], "only Nepal's cities — Delhi (India) must be filtered out")

        let result = waitForValidation(state) {
            state.setValue(ref: "/data/city", index: 0, value: "pokhara", typeXml: "string")
            state.validateQuestion(ref: "/data/city", index: 0)
        }
        XCTAssertEqual(result?.valid, true)
    }

    // MARK: - `appearance="minimal"` / `"autocomplete"` selects
    // Regressions: minimal only found the first option; autocomplete wasn't
    // recognized as a select at all (reported as a plain string, zero options).

    func testMinimalAndAutocompleteAppearanceSelectsReportEveryOption() {
        let state = loadForm(Self.minimalAppearanceForm)

        let single = question(state, "/data/minimal_select")
        XCTAssertEqual(single?.kind, .select1)
        XCTAssertEqual(single?.options.map(\.value), ["a", "b", "c"])

        let multi = question(state, "/data/minimal_multi")
        XCTAssertEqual(multi?.kind, .select)
        XCTAssertEqual(multi?.options.map(\.value), ["red", "blue"])

        let autocomplete = question(state, "/data/autocomplete_select")
        XCTAssertEqual(autocomplete?.kind, .select1)
        XCTAssertEqual(autocomplete?.options.map(\.value), ["1", "2"])
    }

    // MARK: - Repeats

    func testAddingAndRemovingARepeatInstanceIsReflectedInQuestionsAndRepeats() {
        let state = loadForm(Self.repeatForm)
        XCTAssertEqual(state.repeats.first(where: { $0.ref == "/data/g/r" })?.count, 1)

        // `waitForQuestionsUpdate` only waits for *a* next emission — susceptible to
        // the same stale-in-flight-emission race documented on `waitForQuestions`
        // above (a late, pre-action "questions" message can arrive right after
        // `addRepeatInstance`/`removeRepeatInstance` and satisfy it before the real
        // post-action one lands). Waiting on the actual predicate sidesteps it.
        waitForQuestions(state, until: { $0.filter { $0.ref == "/data/g/r/item" }.count == 2 }) {
            state.addRepeatInstance(repeatRef: "/data/g/r")
        }
        XCTAssertEqual(state.repeats.first(where: { $0.ref == "/data/g/r" })?.count, 2)
        XCTAssertEqual(state.questions.filter { $0.ref == "/data/g/r/item" }.count, 2)

        waitForQuestions(state, until: { $0.filter { $0.ref == "/data/g/r/item" }.count == 1 }) {
            state.removeRepeatInstance(repeatRef: "/data/g/r", index: 1)
        }
        XCTAssertEqual(state.repeats.first(where: { $0.ref == "/data/g/r" })?.count, 1)
        XCTAssertEqual(state.questions.filter { $0.ref == "/data/g/r/item" }.count, 1)
    }

    // MARK: - Bikram Sambat

    func testBikramSambatAppearanceIsFlagged() {
        let state = loadForm(Self.bikramSambatForm)
        XCTAssertEqual(question(state, "/data/dob")?.bikramSambat, true)
    }

    /// Verbatim output of `pyxform.xls2xform` for a `type: date, appearance:
    /// bikram-sambat` survey row, alongside an ordinary (non-BS) date question —
    /// confirms the real compiled shape is flagged correctly, distinct from the
    /// hand-written fixture above which could in principle hide an assumption pyxform
    /// doesn't actually share.
    func testRealPyxformBikramSambatDateIsFlaggedAndAnOrdinaryDateIsNot() {
        let xml = """
        <?xml version="1.0"?>
        <h:html xmlns="http://www.w3.org/2002/xforms" xmlns:h="http://www.w3.org/1999/xhtml" xmlns:ev="http://www.w3.org/2001/xml-events" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:jr="http://openrosa.org/javarosa" xmlns:orx="http://openrosa.org/xforms" xmlns:odk="http://www.opendatakit.org/xforms">
          <h:head>
            <h:title>BS Test</h:title>
            <model odk:xforms-version="1.0.0">
              <instance>
                <data id="bs_test">
                  <dob/>
                  <today_date/>
                  <meta>
                    <instanceID/>
                  </meta>
                </data>
              </instance>
              <bind nodeset="/data/dob" type="date"/>
              <bind nodeset="/data/today_date" type="date"/>
              <bind nodeset="/data/meta/instanceID" type="string" readonly="true()" jr:preload="uid"/>
            </model>
          </h:head>
          <h:body>
            <input appearance="bikram-sambat" ref="/data/dob">
              <label>Date of birth</label>
            </input>
            <input ref="/data/today_date">
              <label>Today's date</label>
            </input>
          </h:body>
        </h:html>
        """
        let state = loadForm(xml)
        XCTAssertEqual(question(state, "/data/dob")?.bikramSambat, true)
        XCTAssertEqual(question(state, "/data/today_date")?.bikramSambat, false)
    }

    // MARK: - `select1`/`select` backed by a secondary-instance itemset
    // (regression: "question text not visible" — reported against a real
    // XLSForm-compiled form where pyxform emits a secondary `<instance>` +
    // `<itemset>` for EVERY choice list, even a fully static one with no
    // cascading predicate. enketo-core stamps `data-contains-ref-target` on that
    // itemset's hidden TEMPLATE `<label>` too — the same attribute our bridge
    // used to locate "the question wrapper" — so `getQuestions()`/`findWrapper()`
    // resolved to that empty template instead of the real `.question` fieldset,
    // reporting a blank label/hint (and, for `validateQuestion`, the wrong
    // wrapper to read the constraint/required message back from). This affects
    // *both* the one-question-at-a-time flow and the read-only "all answers at
    // once" summary, since both are driven by the same `state.questions`.)

    func testSelectBackedByStaticSecondaryInstanceItemsetReportsItsLabelHintAndOptions() {
        let state = loadForm(Self.staticSecondaryInstanceItemsetForm)
        let q = question(state, "/data/grievance_details/is_own_grievance")
        XCTAssertEqual(q?.kind, .select1)
        XCTAssertEqual(q?.label, "Is this your own grievance or someone else's?", "used to come back empty — resolved to the itemset's hidden template, not the real question")
        XCTAssertEqual(q?.hint, "Pick one")
        XCTAssertEqual(q?.options, [
            Question.Option(value: "mine", label: "My own"),
            Question.Option(value: "someone_else", label: "Someone else's")
        ])
        // It's the sole member of a `field-list` group — the native flow clusters
        // it (and anything else sharing this ref) into one page instead of
        // showing it alone.
        XCTAssertEqual(q?.fieldListGroupRef, "/data/grievance_details")
        XCTAssertEqual(q?.fieldListGroupLabel, "Grievance Details")

        // Answering it should also flip the dependent field's relevance, and
        // validating it should report the *actual* required-message text (also
        // read via `findWrapper`, so it shared the same bug).
        let emptyResult = waitForValidation(state) {
            state.validateQuestion(ref: "/data/grievance_details/is_own_grievance", index: 0)
        }
        XCTAssertEqual(emptyResult?.valid, false)
        XCTAssertEqual(emptyResult?.message, "This field is required")

        XCTAssertEqual(question(state, "/data/is_confidential")?.relevant, false)
        waitForQuestions(state, until: { $0.first(where: { $0.ref == "/data/is_confidential" })?.relevant == true }) {
            state.setValue(ref: "/data/grievance_details/is_own_grievance", index: 0, value: "someone_else", typeXml: "string")
        }
        XCTAssertEqual(question(state, "/data/is_confidential")?.relevant, true)
    }

    // MARK: - Batch validation for a `field-list` group's page

    func testValidateQuestionsReportsEveryResultTogetherAndAppliesThemAll() {
        let state = loadForm(Self.fieldListGroupForm)
        XCTAssertEqual(question(state, "/data/g/first")?.fieldListGroupRef, "/data/g")
        XCTAssertEqual(question(state, "/data/g/second")?.fieldListGroupRef, "/data/g")

        // Both required and both still empty — batch validation should report
        // both as invalid, not stop at the first.
        let bothEmpty = waitForGroupValidation(state) {
            state.validateQuestions([
                (ref: "/data/g/first", index: 0),
                (ref: "/data/g/second", index: 0)
            ])
        }
        XCTAssertEqual(bothEmpty?.allValid, false)
        XCTAssertEqual(Set(bothEmpty?.results.filter { !$0.valid }.map(\.uid) ?? []), ["/data/g/first[0]", "/data/g/second[0]"])

        waitForQuestions(state, until: { $0.first(where: { $0.ref == "/data/g/first" })?.value == "a" }) {
            state.setValue(ref: "/data/g/first", index: 0, value: "a", typeXml: "string")
        }
        waitForQuestions(state, until: { $0.first(where: { $0.ref == "/data/g/second" })?.value == "b" }) {
            state.setValue(ref: "/data/g/second", index: 0, value: "b", typeXml: "string")
        }
        let bothFilled = waitForGroupValidation(state) {
            state.validateQuestions([
                (ref: "/data/g/first", index: 0),
                (ref: "/data/g/second", index: 0)
            ])
        }
        XCTAssertEqual(bothFilled?.allValid, true)
    }
}

// MARK: - Fixtures

private extension EnketoEngineIntegrationTests {
    static let linearForm = Fixtures.load("linearForm")

    static let metaFieldForm = Fixtures.load("metaFieldForm")

    static let appearanceHiddenForm = Fixtures.load("appearanceHiddenForm")

    static let groupRelevantForm = Fixtures.load("groupRelevantForm")

    static let cascadingSelectForm = Fixtures.load("cascadingSelectForm")

    static let minimalAppearanceForm = Fixtures.load("minimalAppearanceForm")

    static let repeatForm = Fixtures.load("repeatForm")

    static let bikramSambatForm = Fixtures.load("bikramSambatForm")

    /// Mirrors what pyxform 2.x actually emits for a `select_one <list>` — a
    /// secondary `<instance>` + `<itemset>` with no cascading predicate — nested
    /// inside a `field-list` group, exactly as reported.
    static let staticSecondaryInstanceItemsetForm = Fixtures.load("staticSecondaryInstanceItemsetForm")

    static let fieldListGroupForm = Fixtures.load("fieldListGroupForm")
}
