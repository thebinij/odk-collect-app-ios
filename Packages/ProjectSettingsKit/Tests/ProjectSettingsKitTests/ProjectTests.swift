import XCTest
@testable import ProjectSettingsKit

final class ProjectTests: XCTestCase {
    private let serverURL = URL(string: "https://odk.example.org")!

    func testEquatable() {
        let a = Project(serverURL: serverURL, username: "alice")
        let b = Project(serverURL: serverURL, username: "alice")
        let c = Project(serverURL: serverURL, username: "bob")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
