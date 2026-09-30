import XCTest
@testable import ProjectSettingsKit

final class ProjectStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var keychain: KeychainStore!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ProjectStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        keychain = KeychainStore(service: "com.odkcollect.tests.\(UUID().uuidString)", account: "password")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        keychain.deletePassword()
        super.tearDown()
    }

    func testClearResetsEveryFieldAndRemovesTheKeychainPassword() {
        let store = ProjectStore(defaults: defaults, keychain: keychain)
        store.serverURLText = "https://odk.example.org"
        store.username = "alice"
        store.password = "secret"
        XCTAssertEqual(keychain.readPassword(), "secret")

        store.clear()

        XCTAssertEqual(store.serverURLText, "")
        XCTAssertEqual(store.username, "")
        XCTAssertEqual(store.password, "")
        XCTAssertNil(keychain.readPassword())
        XCTAssertNil(store.project)
    }

    func testClearedStoreDoesNotResurrectTheOldValuesOnRelaunch() {
        let store = ProjectStore(defaults: defaults, keychain: keychain)
        store.serverURLText = "https://odk.example.org"
        store.username = "alice"
        store.password = "secret"
        store.clear()

        // A fresh `ProjectStore` reading the same backing storage (simulating an app
        // relaunch) should come up blank, not with the pre-`clear()` values.
        let relaunched = ProjectStore(defaults: defaults, keychain: keychain)
        XCTAssertEqual(relaunched.serverURLText, "")
        XCTAssertEqual(relaunched.username, "")
        XCTAssertEqual(relaunched.password, "")
    }
}
