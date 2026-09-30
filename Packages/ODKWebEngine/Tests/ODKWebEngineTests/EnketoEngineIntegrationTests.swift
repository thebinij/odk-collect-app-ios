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

        waitForQuestionsUpdate(state) {
            state.addRepeatInstance(repeatRef: "/data/g/r")
        }
        XCTAssertEqual(state.repeats.first(where: { $0.ref == "/data/g/r" })?.count, 2)
        XCTAssertEqual(state.questions.filter { $0.ref == "/data/g/r/item" }.count, 2)

        waitForQuestionsUpdate(state) {
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
    static let linearForm = """
    <?xml version="1.0"?>
    <h:html xmlns="http://www.w3.org/2002/xforms" xmlns:h="http://www.w3.org/1999/xhtml" xmlns:ev="http://www.w3.org/2001/xml-events" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:jr="http://openrosa.org/javarosa" xmlns:orx="http://openrosa.org/xforms">
      <h:head><h:title>Linear</h:title>
        <model>
          <instance><data id="linear"><name/><age/><meta><instanceID/></meta></data></instance>
          <bind nodeset="/data/name" type="string" required="true()"/>
          <bind nodeset="/data/age" type="int"/>
          <bind nodeset="/data/meta/instanceID" type="string" readonly="true()" calculate="concat('uuid:', uuid())"/>
        </model>
      </h:head>
      <h:body>
        <input ref="/data/name"><label>Name</label></input>
        <input ref="/data/age"><label>Age</label></input>
      </h:body>
    </h:html>
    """

    static let metaFieldForm = """
    <?xml version="1.0"?>
    <h:html xmlns="http://www.w3.org/2002/xforms" xmlns:h="http://www.w3.org/1999/xhtml" xmlns:ev="http://www.w3.org/2001/xml-events" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:jr="http://openrosa.org/javarosa" xmlns:orx="http://openrosa.org/xforms">
      <h:head><h:title>MetaField</h:title>
        <model>
          <instance><data id="mf"><name/><meta><instanceID/><instanceName/></meta></data></instance>
          <bind nodeset="/data/name" type="string"/>
          <bind nodeset="/data/meta/instanceID" type="string" readonly="true()" calculate="concat('uuid:', uuid())"/>
          <bind nodeset="/data/meta/instanceName" type="string" readonly="true()" calculate="/data/name"/>
        </model>
      </h:head>
      <h:body>
        <input ref="/data/name"><label>Name</label></input>
        <input ref="/data/meta/instanceName"><label>Instance Name (still meta, even though it's in the body)</label></input>
      </h:body>
    </h:html>
    """

    static let appearanceHiddenForm = """
    <?xml version="1.0"?>
    <h:html xmlns="http://www.w3.org/2002/xforms" xmlns:h="http://www.w3.org/1999/xhtml" xmlns:ev="http://www.w3.org/2001/xml-events" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:jr="http://openrosa.org/javarosa" xmlns:orx="http://openrosa.org/xforms">
      <h:head><h:title>Hidden</h:title>
        <model>
          <instance><data id="hd"><secret/><meta><instanceID/></meta></data></instance>
          <bind nodeset="/data/secret" type="string"/>
          <bind nodeset="/data/meta/instanceID" type="string" readonly="true()" calculate="concat('uuid:', uuid())"/>
        </model>
      </h:head>
      <h:body>
        <input ref="/data/secret" appearance="hidden"><label>Secret</label></input>
      </h:body>
    </h:html>
    """

    static let groupRelevantForm = """
    <?xml version="1.0"?>
    <h:html xmlns="http://www.w3.org/2002/xforms" xmlns:h="http://www.w3.org/1999/xhtml" xmlns:ev="http://www.w3.org/2001/xml-events" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:jr="http://openrosa.org/javarosa" xmlns:orx="http://openrosa.org/xforms">
      <h:head><h:title>GroupRelevant</h:title>
        <model>
          <instance><data id="gr"><gate/><g1><a/></g1><meta><instanceID/></meta></data></instance>
          <bind nodeset="/data/gate" type="string"/>
          <bind nodeset="/data/g1" relevant="/data/gate = 'yes'"/>
          <bind nodeset="/data/g1/a" type="string" required="true()"/>
          <bind nodeset="/data/meta/instanceID" type="string" readonly="true()" calculate="concat('uuid:', uuid())"/>
        </model>
      </h:head>
      <h:body>
        <select1 ref="/data/gate"><label>Gate</label>
          <item><label>Yes</label><value>yes</value></item>
          <item><label>No</label><value>no</value></item>
        </select1>
        <group ref="/data/g1" appearance="field-list">
          <label>Section G1</label>
          <input ref="/data/g1/a"><label>A</label></input>
        </group>
      </h:body>
    </h:html>
    """

    static let cascadingSelectForm = """
    <?xml version="1.0"?>
    <h:html xmlns="http://www.w3.org/2002/xforms" xmlns:h="http://www.w3.org/1999/xhtml" xmlns:ev="http://www.w3.org/2001/xml-events" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:jr="http://openrosa.org/javarosa" xmlns:orx="http://openrosa.org/xforms">
      <h:head><h:title>Cascading</h:title>
        <model>
          <instance><data id="cas"><country/><city/><meta><instanceID/></meta></data></instance>
          <instance id="cities">
            <root>
              <item><itextId>static_instance-cities-0</itextId><country>np</country><name>kathmandu</name></item>
              <item><itextId>static_instance-cities-1</itextId><country>np</country><name>pokhara</name></item>
              <item><itextId>static_instance-cities-2</itextId><country>in</country><name>delhi</name></item>
            </root>
          </instance>
          <itext>
            <translation lang="en">
              <text id="static_instance-cities-0"><value>Kathmandu</value></text>
              <text id="static_instance-cities-1"><value>Pokhara</value></text>
              <text id="static_instance-cities-2"><value>Delhi</value></text>
            </translation>
          </itext>
          <bind nodeset="/data/country" type="string"/>
          <bind nodeset="/data/city" type="string" required="true()"/>
          <bind nodeset="/data/meta/instanceID" type="string" readonly="true()" calculate="concat('uuid:', uuid())"/>
        </model>
      </h:head>
      <h:body>
        <select1 ref="/data/country"><label>Country</label>
          <item><label>Nepal</label><value>np</value></item>
          <item><label>India</label><value>in</value></item>
        </select1>
        <select1 ref="/data/city">
          <label>City</label>
          <itemset nodeset="instance('cities')/root/item[country = /data/country]">
            <value ref="name"/>
            <label ref="jr:itext(itextId)"/>
          </itemset>
        </select1>
      </h:body>
    </h:html>
    """

    static let minimalAppearanceForm = """
    <?xml version="1.0"?>
    <h:html xmlns="http://www.w3.org/2002/xforms" xmlns:h="http://www.w3.org/1999/xhtml" xmlns:ev="http://www.w3.org/2001/xml-events" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:jr="http://openrosa.org/javarosa" xmlns:orx="http://openrosa.org/xforms">
      <h:head><h:title>MinimalAutocomplete</h:title>
        <model>
          <instance><data id="ma"><minimal_select/><minimal_multi/><autocomplete_select/><meta><instanceID/></meta></data></instance>
          <bind nodeset="/data/minimal_select" type="string"/>
          <bind nodeset="/data/minimal_multi" type="string"/>
          <bind nodeset="/data/autocomplete_select" type="string"/>
          <bind nodeset="/data/meta/instanceID" type="string" readonly="true()" calculate="concat('uuid:', uuid())"/>
        </model>
      </h:head>
      <h:body>
        <select1 ref="/data/minimal_select" appearance="minimal">
          <label>Pick one (minimal)</label>
          <item><label>Alpha</label><value>a</value></item>
          <item><label>Beta</label><value>b</value></item>
          <item><label>Gamma</label><value>c</value></item>
        </select1>
        <select ref="/data/minimal_multi" appearance="minimal">
          <label>Pick many (minimal)</label>
          <item><label>Red</label><value>red</value></item>
          <item><label>Blue</label><value>blue</value></item>
        </select>
        <select1 ref="/data/autocomplete_select" appearance="autocomplete">
          <label>Pick one (autocomplete)</label>
          <item><label>One</label><value>1</value></item>
          <item><label>Two</label><value>2</value></item>
        </select1>
      </h:body>
    </h:html>
    """

    static let repeatForm = """
    <?xml version="1.0"?>
    <h:html xmlns="http://www.w3.org/2002/xforms" xmlns:h="http://www.w3.org/1999/xhtml" xmlns:ev="http://www.w3.org/2001/xml-events" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:jr="http://openrosa.org/javarosa" xmlns:orx="http://openrosa.org/xforms">
      <h:head><h:title>Repeat</h:title>
        <model>
          <instance><data id="rep"><g><r><item/></r></g><meta><instanceID/></meta></data></instance>
          <bind nodeset="/data/g/r/item" type="string"/>
          <bind nodeset="/data/meta/instanceID" type="string" readonly="true()" calculate="concat('uuid:', uuid())"/>
        </model>
      </h:head>
      <h:body>
        <group ref="/data/g">
          <label>Group G</label>
          <repeat nodeset="/data/g/r">
            <input ref="/data/g/r/item"><label>Item</label></input>
          </repeat>
        </group>
      </h:body>
    </h:html>
    """

    static let bikramSambatForm = """
    <?xml version="1.0"?>
    <h:html xmlns="http://www.w3.org/2002/xforms" xmlns:h="http://www.w3.org/1999/xhtml" xmlns:ev="http://www.w3.org/2001/xml-events" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:jr="http://openrosa.org/javarosa" xmlns:orx="http://openrosa.org/xforms">
      <h:head><h:title>BS</h:title>
        <model>
          <instance><data id="bs"><dob/><meta><instanceID/></meta></data></instance>
          <bind nodeset="/data/dob" type="date"/>
          <bind nodeset="/data/meta/instanceID" type="string" readonly="true()" calculate="concat('uuid:', uuid())"/>
        </model>
      </h:head>
      <h:body>
        <input ref="/data/dob" appearance="bikram-sambat"><label>Date of birth</label></input>
      </h:body>
    </h:html>
    """

    /// Mirrors what pyxform 2.x actually emits for a `select_one <list>` — a
    /// secondary `<instance>` + `<itemset>` with no cascading predicate — nested
    /// inside a `field-list` group, exactly as reported.
    static let staticSecondaryInstanceItemsetForm = """
    <?xml version="1.0"?>
    <h:html xmlns="http://www.w3.org/2002/xforms" xmlns:h="http://www.w3.org/1999/xhtml" xmlns:ev="http://www.w3.org/2001/xml-events" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:jr="http://openrosa.org/javarosa" xmlns:orx="http://openrosa.org/xforms">
      <h:head><h:title>Itemset</h:title>
        <model>
          <instance>
            <data id="itemset-form">
              <grievance_details><is_own_grievance/></grievance_details>
              <is_confidential/>
              <meta><instanceID/></meta>
            </data>
          </instance>
          <instance id="grievance_owner">
            <root>
              <item><name>mine</name><label>My own</label></item>
              <item><name>someone_else</name><label>Someone else's</label></item>
            </root>
          </instance>
          <bind nodeset="/data/grievance_details/is_own_grievance" type="string" required="true()"/>
          <bind nodeset="/data/is_confidential" type="string" relevant="/data/grievance_details/is_own_grievance = 'someone_else'"/>
          <bind nodeset="/data/meta/instanceID" type="string" readonly="true()" calculate="concat('uuid:', uuid())"/>
        </model>
      </h:head>
      <h:body>
        <group appearance="field-list" ref="/data/grievance_details">
          <label>Grievance Details</label>
          <select1 ref="/data/grievance_details/is_own_grievance">
            <label>Is this your own grievance or someone else's?</label>
            <hint>Pick one</hint>
            <itemset nodeset="instance('grievance_owner')/root/item">
              <value ref="name"/>
              <label ref="label"/>
            </itemset>
          </select1>
        </group>
        <input ref="/data/is_confidential"><label>Confidential?</label></input>
      </h:body>
    </h:html>
    """

    static let fieldListGroupForm = """
    <?xml version="1.0"?>
    <h:html xmlns="http://www.w3.org/2002/xforms" xmlns:h="http://www.w3.org/1999/xhtml" xmlns:ev="http://www.w3.org/2001/xml-events" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:jr="http://openrosa.org/javarosa" xmlns:orx="http://openrosa.org/xforms">
      <h:head><h:title>FieldList</h:title>
        <model>
          <instance><data id="fl"><g><first/><second/></g><meta><instanceID/></meta></data></instance>
          <bind nodeset="/data/g/first" type="string" required="true()"/>
          <bind nodeset="/data/g/second" type="string" required="true()"/>
          <bind nodeset="/data/meta/instanceID" type="string" readonly="true()" calculate="concat('uuid:', uuid())"/>
        </model>
      </h:head>
      <h:body>
        <group ref="/data/g" appearance="field-list">
          <label>Group G</label>
          <input ref="/data/g/first"><label>First</label></input>
          <input ref="/data/g/second"><label>Second</label></input>
        </group>
      </h:body>
    </h:html>
    """
}
