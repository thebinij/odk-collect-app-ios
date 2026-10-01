import XCTest
@testable import ProjectSettingsKit

final class FormSubmissionSettingsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "FormSubmissionSettingsStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultsToOff() {
        let store = FormSubmissionSettingsStore(defaults: defaults)
        XCTAssertEqual(store.autoSend, .off)
    }

    func testSettingPersistsImmediately() {
        let store = FormSubmissionSettingsStore(defaults: defaults)
        store.autoSend = .wifiOrCellular

        // Same backing storage, new instance — simulating an app relaunch.
        let relaunched = FormSubmissionSettingsStore(defaults: defaults)
        XCTAssertEqual(relaunched.autoSend, .wifiOrCellular)

        relaunched.autoSend = .off
        XCTAssertEqual(FormSubmissionSettingsStore(defaults: defaults).autoSend, .off)
    }

    func testEachModePersists() {
        for mode in AutoSendMode.allCases {
            let suite = "FormSubmissionSettingsStoreTests.mode.\(mode.rawValue)"
            let d = UserDefaults(suiteName: suite)!
            defer { d.removePersistentDomain(forName: suite) }

            let store = FormSubmissionSettingsStore(defaults: d)
            store.autoSend = mode
            XCTAssertEqual(FormSubmissionSettingsStore(defaults: d).autoSend, mode)
        }
    }

    func testUnrecognizedStoredValueFallsBackToOff() {
        defaults.set("nonsense", forKey: "com.odkcollect.formSubmission.autoSend")
        let store = FormSubmissionSettingsStore(defaults: defaults)
        XCTAssertEqual(store.autoSend, .off)
    }

    // MARK: - Migration from the prior manual/automatic build

    func testMigratesLegacyManualToOff() {
        defaults.set("manual", forKey: "com.odkcollect.sendSettings.mode")
        XCTAssertEqual(FormSubmissionSettingsStore(defaults: defaults).autoSend, .off)
    }

    func testMigratesLegacyAutomaticToWifiOrCellular() {
        defaults.set("automatic", forKey: "com.odkcollect.sendSettings.mode")
        XCTAssertEqual(FormSubmissionSettingsStore(defaults: defaults).autoSend, .wifiOrCellular)
    }

    func testNewKeyTakesPrecedenceOverLegacyKey() {
        defaults.set("automatic", forKey: "com.odkcollect.sendSettings.mode")
        defaults.set("cellularOnly", forKey: "com.odkcollect.formSubmission.autoSend")
        XCTAssertEqual(FormSubmissionSettingsStore(defaults: defaults).autoSend, .cellularOnly)
    }
}
