import XCTest
@testable import OpenRosaKit

final class FormCacheStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var store: FormCacheStore!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = FormCacheStore(directory: tempDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testCachedFormListIsNilBeforeAnythingIsCached() {
        XCTAssertNil(store.cachedFormList())
    }

    func testFormListRoundTrips() {
        let forms = [
            RemoteForm(formID: "f1", name: "Form One", version: "1", hash: "md5:abc", downloadURL: URL(string: "https://example.org/f1.xml")!, manifestURL: nil),
            RemoteForm(formID: "f2", name: "Form Two", version: nil, hash: nil, downloadURL: URL(string: "https://example.org/f2.xml")!, manifestURL: URL(string: "https://example.org/f2/manifest")!)
        ]
        store.cacheFormList(forms)
        XCTAssertEqual(store.cachedFormList(), forms)
    }

    func testCachingAFormListOverwritesThePreviousOne() {
        let first = [RemoteForm(formID: "f1", name: "Form One", version: nil, hash: nil, downloadURL: URL(string: "https://example.org/f1.xml")!, manifestURL: nil)]
        let second = [RemoteForm(formID: "f2", name: "Form Two", version: nil, hash: nil, downloadURL: URL(string: "https://example.org/f2.xml")!, manifestURL: nil)]
        store.cacheFormList(first)
        store.cacheFormList(second)
        XCTAssertEqual(store.cachedFormList(), second)
    }

    func testCachedFormXMLIsNilBeforeItsCached() {
        XCTAssertNil(store.cachedFormXML(formID: "f1"))
    }

    func testFormXMLRoundTrips() {
        store.cacheFormXML("<h:html><!--form f1--></h:html>", formID: "f1")
        XCTAssertEqual(store.cachedFormXML(formID: "f1"), "<h:html><!--form f1--></h:html>")
    }

    func testCachedFormDownloadDateIsNilBeforeItsCached() {
        XCTAssertNil(store.cachedFormDownloadDate(formID: "f1"))
    }

    func testCachedFormDownloadDateRoundTrips() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        store.cacheFormXML("<h:html/>", formID: "f1", downloadedAt: date)
        XCTAssertEqual(store.cachedFormDownloadDate(formID: "f1"), date)
    }

    /// Re-caching the same form (e.g. a background sync re-fetching a form that
    /// changed) must update its download date, not keep the original one.
    func testRecachingAFormUpdatesItsDownloadDate() {
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = Date(timeIntervalSince1970: 1_800_000_000)
        store.cacheFormXML("<h:html>v1</h:html>", formID: "f1", downloadedAt: firstDate)
        store.cacheFormXML("<h:html>v2</h:html>", formID: "f1", downloadedAt: secondDate)
        XCTAssertEqual(store.cachedFormXML(formID: "f1"), "<h:html>v2</h:html>")
        XCTAssertEqual(store.cachedFormDownloadDate(formID: "f1"), secondDate)
    }

    func testDifferentFormIDsAreCachedIndependently() {
        store.cacheFormXML("<h:html>one</h:html>", formID: "f1")
        store.cacheFormXML("<h:html>two</h:html>", formID: "f2")
        XCTAssertEqual(store.cachedFormXML(formID: "f1"), "<h:html>one</h:html>")
        XCTAssertEqual(store.cachedFormXML(formID: "f2"), "<h:html>two</h:html>")
    }

    /// Real OpenRosa `formID`s aren't guaranteed to be filesystem-safe (they can
    /// contain `/`, spaces, colons, ...) — caching one must not throw or silently
    /// collide with another form's cache entry.
    func testFormIDsWithFilesystemUnsafeCharactersAreCachedCorrectly() {
        let trickyID = "widgets/survey 2024:v1"
        store.cacheFormXML("<h:html>tricky</h:html>", formID: trickyID)
        XCTAssertEqual(store.cachedFormXML(formID: trickyID), "<h:html>tricky</h:html>")
    }

    func testCacheSurvivesAcrossStoreInstancesBackedByTheSameDirectory() {
        let forms = [RemoteForm(formID: "f1", name: "Form One", version: nil, hash: nil, downloadURL: URL(string: "https://example.org/f1.xml")!, manifestURL: nil)]
        store.cacheFormList(forms)
        store.cacheFormXML("<h:html/>", formID: "f1")

        let reloaded = FormCacheStore(directory: tempDirectory)
        XCTAssertEqual(reloaded.cachedFormList(), forms)
        XCTAssertEqual(reloaded.cachedFormXML(formID: "f1"), "<h:html/>")
    }
}
