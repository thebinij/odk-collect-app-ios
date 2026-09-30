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

    func testSaveWithDraftStatusAppearsOnlyInDrafts() throws {
        let saved = try store.save(xml: "<data/>", xformXML: "<h:html/>", formID: "f1", formName: "Form One", status: .draft)
        XCTAssertEqual(saved.status, .draft)
        XCTAssertEqual(store.draftSubmissions.count, 1)
        XCTAssertEqual(store.readyToSendSubmissions.count, 0)
        XCTAssertEqual(store.sentSubmissions.count, 0)
    }

    /// The whole point of splitting this out from `.draft`: a fully answered form
    /// that just failed to upload must show up in Ready to Send, not get conflated
    /// with an incomplete, still-being-filled-in draft.
    func testSaveWithReadyToSendStatusAppearsOnlyInReadyToSend() throws {
        let saved = try store.save(xml: "<data/>", xformXML: "<h:html/>", formID: "f1", formName: "Form One", status: .readyToSend)
        XCTAssertEqual(saved.status, .readyToSend)
        XCTAssertEqual(store.readyToSendSubmissions.count, 1)
        XCTAssertEqual(store.draftSubmissions.count, 0)
        XCTAssertEqual(store.sentSubmissions.count, 0)
    }

    /// Resuming a draft and completing it, then tapping "Send", must move the *same*
    /// entry from Drafts to Ready to Send — not leave a stale duplicate behind in
    /// Drafts while a new entry appears in Ready to Send.
    func testSavingAnExistingDraftAsReadyToSendMovesItRatherThanDuplicating() throws {
        let draft = try store.save(xml: "<data/>", xformXML: "<h:html/>", formID: "f1", formName: "Form One", status: .draft)
        let updated = try store.save(
            xml: "<data><a>done</a></data>",
            xformXML: "<h:html/>",
            formID: "f1",
            formName: "Form One",
            status: .readyToSend,
            existingID: draft.id
        )
        XCTAssertEqual(draft.id, updated.id)
        XCTAssertEqual(store.submissions.count, 1, "must update in place, not create a second entry")
        XCTAssertEqual(store.draftSubmissions.count, 0)
        XCTAssertEqual(store.readyToSendSubmissions.count, 1)
    }

    func testSavedXMLAndXFormXMLRoundTrip() throws {
        let saved = try store.save(xml: "<data><a>1</a></data>", xformXML: "<h:html><!--form--></h:html>", formID: "f1", formName: "Form One", status: .draft)
        XCTAssertEqual(String(decoding: try store.xmlData(for: saved.id), as: UTF8.self), "<data><a>1</a></data>")
        XCTAssertEqual(try store.xformXML(for: saved.id), "<h:html><!--form--></h:html>")
    }

    func testSavingWithExistingIDUpdatesInPlaceRatherThanDuplicating() throws {
        let first = try store.save(xml: "<data><a>1</a></data>", xformXML: "<h:html/>", formID: "f1", formName: "Form One", status: .draft)
        let second = try store.save(
            xml: "<data><a>2</a></data>",
            xformXML: "<h:html/>",
            formID: "f1",
            formName: "Form One",
            status: .draft,
            existingID: first.id
        )
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.submissions.count, 1)
        XCTAssertEqual(String(decoding: try store.xmlData(for: second.id), as: UTF8.self), "<data><a>2</a></data>")
    }

    func testExistingIDPreservesOriginalCreatedAt() throws {
        let first = try store.save(xml: "<data/>", xformXML: "<h:html/>", formID: "f1", formName: "Form One", status: .draft)
        // Simulate time passing between the initial draft save and a later edit.
        Thread.sleep(forTimeInterval: 0.01)
        let second = try store.save(xml: "<data/>", xformXML: "<h:html/>", formID: "f1", formName: "Form One", status: .draft, existingID: first.id)
        XCTAssertEqual(first.createdAt, second.createdAt)
    }

    func testMarkSentMovesSubmissionFromReadyToSendToSent() throws {
        let saved = try store.save(xml: "<data/>", xformXML: "<h:html/>", formID: "f1", formName: "Form One", status: .readyToSend)
        store.markSent(saved.id)
        XCTAssertEqual(store.readyToSendSubmissions.count, 0)
        XCTAssertEqual(store.sentSubmissions.count, 1)
        XCTAssertNotNil(store.sentSubmissions.first?.sentAt)
    }

    func testDeleteRemovesTheSubmissionAndItsFiles() throws {
        let saved = try store.save(xml: "<data/>", xformXML: "<h:html/>", formID: "f1", formName: "Form One", status: .draft)
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
            status: .draft,
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
            status: .draft,
            attachments: ["a.jpg": Data([1])]
        )
        let second = try store.save(
            xml: "<data/>",
            xformXML: "<h:html/>",
            formID: "f1",
            formName: "Form One",
            status: .draft,
            attachments: ["b.jpg": Data([2])],
            existingID: first.id
        )
        XCTAssertEqual(Set(store.attachmentFilenames(for: second.id)), ["a.jpg", "b.jpg"])
    }

    /// A submission folder missing `form.xml` (e.g. written by a build predating that
    /// file being saved) must not be surfaced — opening it would otherwise fail with
    /// a raw "no such file" error.
    func testReloadSkipsEntriesMissingFormXML() throws {
        let saved = try store.save(xml: "<data/>", xformXML: "<h:html/>", formID: "f1", formName: "Form One", status: .draft)
        try FileManager.default.removeItem(
            at: tempDirectory.appendingPathComponent(saved.id).appendingPathComponent("form.xml")
        )

        let reloaded = SubmissionStore(directory: tempDirectory)
        XCTAssertTrue(reloaded.submissions.isEmpty)
    }

    /// Same, but for a folder missing `submission.xml` instead.
    func testReloadSkipsEntriesMissingInstanceXML() throws {
        let saved = try store.save(xml: "<data/>", xformXML: "<h:html/>", formID: "f1", formName: "Form One", status: .draft)
        try FileManager.default.removeItem(
            at: tempDirectory.appendingPathComponent(saved.id).appendingPathComponent("submission.xml")
        )

        let reloaded = SubmissionStore(directory: tempDirectory)
        XCTAssertTrue(reloaded.submissions.isEmpty)
    }

    func testSubmissionsPersistAcrossStoreInstancesBackedByTheSameDirectory() throws {
        let saved = try store.save(xml: "<data/>", xformXML: "<h:html/>", formID: "f1", formName: "Form One", status: .draft)
        let reloaded = SubmissionStore(directory: tempDirectory)
        XCTAssertEqual(reloaded.submissions.map(\.id), [saved.id])
    }

    /// The `status` itself must also survive a reload — not just the submission's
    /// existence — since Drafts/Ready to Send/Sent all read from it.
    func testStatusPersistsAcrossStoreInstances() throws {
        let saved = try store.save(xml: "<data/>", xformXML: "<h:html/>", formID: "f1", formName: "Form One", status: .readyToSend)
        let reloaded = SubmissionStore(directory: tempDirectory)
        XCTAssertEqual(reloaded.submissions.first(where: { $0.id == saved.id })?.status, .readyToSend)
    }

    func testDraftAndReadyToSendAreSortedNewestFirst() throws {
        let older = try store.save(xml: "<data/>", xformXML: "<h:html/>", formID: "f1", formName: "Older", status: .draft)
        Thread.sleep(forTimeInterval: 0.01)
        let newer = try store.save(xml: "<data/>", xformXML: "<h:html/>", formID: "f1", formName: "Newer", status: .draft)
        XCTAssertEqual(store.draftSubmissions.map(\.id), [newer.id, older.id])
    }
}
