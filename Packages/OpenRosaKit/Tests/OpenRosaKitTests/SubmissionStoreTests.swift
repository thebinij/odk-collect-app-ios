import XCTest
@testable import OpenRosaKit

final class SubmissionStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var store: SubmissionStore!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = SubmissionStore(directory: tempDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testSaveCreatesAPendingSubmission() throws {
        let saved = try store.save(xml: "<data/>", xformXML: "<h:html/>", formID: "f1", formName: "Form One")
        XCTAssertEqual(saved.status, .pending)
        XCTAssertEqual(saved.formID, "f1")
        XCTAssertEqual(store.pendingSubmissions.count, 1)
        XCTAssertEqual(store.sentSubmissions.count, 0)
    }

    func testSavedXMLAndXFormXMLRoundTrip() throws {
        let saved = try store.save(xml: "<data><a>1</a></data>", xformXML: "<h:html><!--form--></h:html>", formID: "f1", formName: "Form One")
        XCTAssertEqual(String(decoding: try store.xmlData(for: saved.id), as: UTF8.self), "<data><a>1</a></data>")
        XCTAssertEqual(try store.xformXML(for: saved.id), "<h:html><!--form--></h:html>")
    }

    func testSavingWithExistingIDUpdatesInPlaceRatherThanDuplicating() throws {
        let first = try store.save(xml: "<data><a>1</a></data>", xformXML: "<h:html/>", formID: "f1", formName: "Form One")
        let second = try store.save(
            xml: "<data><a>2</a></data>",
            xformXML: "<h:html/>",
            formID: "f1",
            formName: "Form One",
            existingID: first.id
        )
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.submissions.count, 1)
        XCTAssertEqual(String(decoding: try store.xmlData(for: second.id), as: UTF8.self), "<data><a>2</a></data>")
    }

    func testExistingIDPreservesOriginalCreatedAt() throws {
        let first = try store.save(xml: "<data/>", xformXML: "<h:html/>", formID: "f1", formName: "Form One")
        // Simulate time passing between the initial draft save and a later edit.
        Thread.sleep(forTimeInterval: 0.01)
        let second = try store.save(xml: "<data/>", xformXML: "<h:html/>", formID: "f1", formName: "Form One", existingID: first.id)
        XCTAssertEqual(first.createdAt, second.createdAt)
    }

    func testMarkSentMovesSubmissionFromPendingToSent() throws {
        let saved = try store.save(xml: "<data/>", xformXML: "<h:html/>", formID: "f1", formName: "Form One")
        store.markSent(saved.id)
        XCTAssertEqual(store.pendingSubmissions.count, 0)
        XCTAssertEqual(store.sentSubmissions.count, 1)
        XCTAssertNotNil(store.sentSubmissions.first?.sentAt)
    }

    func testDeleteRemovesTheSubmissionAndItsFiles() throws {
        let saved = try store.save(xml: "<data/>", xformXML: "<h:html/>", formID: "f1", formName: "Form One")
        try store.delete(saved.id)
        XCTAssertEqual(store.submissions.count, 0)
        XCTAssertThrowsError(try store.xmlData(for: saved.id))
    }

    func testAttachmentsAreSavedAndReadableByFilename() throws {
        let photoData = Data([0xFF, 0xD8, 0xFF])
        let saved = try store.save(
            xml: "<data><photo>photo1.jpg</photo></data>",
            xformXML: "<h:html/>",
            formID: "f1",
            formName: "Form One",
            attachments: ["photo1.jpg": photoData]
        )
        XCTAssertEqual(store.attachmentFilenames(for: saved.id), ["photo1.jpg"])
        XCTAssertEqual(try store.attachmentData(for: saved.id, filename: "photo1.jpg"), photoData)
    }

    func testAttachmentsFromEarlierSavesArePreservedWhenSavingAgainWithoutThem() throws {
        let first = try store.save(
            xml: "<data/>",
            xformXML: "<h:html/>",
            formID: "f1",
            formName: "Form One",
            attachments: ["a.jpg": Data([1])]
        )
        let second = try store.save(
            xml: "<data/>",
            xformXML: "<h:html/>",
            formID: "f1",
            formName: "Form One",
            attachments: ["b.jpg": Data([2])],
            existingID: first.id
        )
        XCTAssertEqual(Set(store.attachmentFilenames(for: second.id)), ["a.jpg", "b.jpg"])
    }

    /// A submission folder missing `form.xml` (e.g. written by a build predating that
    /// file being saved) must not be surfaced — opening it would otherwise fail with
    /// a raw "no such file" error.
    func testReloadSkipsEntriesMissingFormXML() throws {
        let saved = try store.save(xml: "<data/>", xformXML: "<h:html/>", formID: "f1", formName: "Form One")
        try FileManager.default.removeItem(
            at: tempDirectory.appendingPathComponent(saved.id).appendingPathComponent("form.xml")
        )

        let reloaded = SubmissionStore(directory: tempDirectory)
        XCTAssertTrue(reloaded.submissions.isEmpty)
    }

    /// Same, but for a folder missing `submission.xml` instead.
    func testReloadSkipsEntriesMissingInstanceXML() throws {
        let saved = try store.save(xml: "<data/>", xformXML: "<h:html/>", formID: "f1", formName: "Form One")
        try FileManager.default.removeItem(
            at: tempDirectory.appendingPathComponent(saved.id).appendingPathComponent("submission.xml")
        )

        let reloaded = SubmissionStore(directory: tempDirectory)
        XCTAssertTrue(reloaded.submissions.isEmpty)
    }

    func testSubmissionsPersistAcrossStoreInstancesBackedByTheSameDirectory() throws {
        let saved = try store.save(xml: "<data/>", xformXML: "<h:html/>", formID: "f1", formName: "Form One")
        let reloaded = SubmissionStore(directory: tempDirectory)
        XCTAssertEqual(reloaded.submissions.map(\.id), [saved.id])
    }

    func testPendingAndSentAreSortedNewestFirst() throws {
        let older = try store.save(xml: "<data/>", xformXML: "<h:html/>", formID: "f1", formName: "Older")
        Thread.sleep(forTimeInterval: 0.01)
        let newer = try store.save(xml: "<data/>", xformXML: "<h:html/>", formID: "f1", formName: "Newer")
        XCTAssertEqual(store.pendingSubmissions.map(\.id), [newer.id, older.id])
    }
}
