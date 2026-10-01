import Foundation

/// Local, on-disk queue of filled-in forms, with three states — mirroring ODK
/// Collect (Android)'s own instance statuses (`INCOMPLETE`/`COMPLETE`+
/// `SUBMISSION_FAILED`/`SUBMITTED`):
///
/// - `.draft`: an explicit mid-form "Save Draft" checkpoint — possibly incomplete,
///   meant to be reopened in the normal question-by-question flow.
/// - `.readyToSend`: the form was fully answered and "Send" was tapped, but the
///   upload hasn't succeeded yet (most commonly: no network at that moment). It's
///   done, just waiting to actually reach the server — shown separately from
///   `.draft` so "still being filled in" and "finished, just needs to go out" are
///   never conflated.
/// - `.sent`: the upload succeeded.
///
/// Every save is persisted locally *first*, before any network attempt, so nothing
/// is ever lost without a connection. Each submission also keeps a copy of the
/// form's own XForm XML alongside the instance data, so both a `.draft` and a
/// `.readyToSend` entry can be reopened/resent entirely offline — no need to
/// re-download the form definition.
public final class SubmissionStore: ObservableObject {
    public enum Status: String, Codable {
        case draft
        case readyToSend
        case sent
    }

    public struct Submission: Identifiable, Codable, Equatable {
        public let id: String
        public let formID: String
        public let formName: String
        public let createdAt: Date
        public var status: Status
        public var sentAt: Date?
    }

    @Published public private(set) var submissions: [Submission] = []

    private let directory: URL
    private let fileManager = FileManager.default

    /// Transient (never persisted) record of which submissions currently have an
    /// upload in flight, so two send paths — a manual tap and an automatic sweep —
    /// can never POST the same submission twice. Meaningless across launches, which
    /// is fine: nothing is in flight at launch.
    private var sendingIDs: Set<String> = []

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = base.appendingPathComponent("Submissions", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        reload()
    }

    public var draftSubmissions: [Submission] {
        submissions.filter { $0.status == .draft }.sorted { $0.createdAt > $1.createdAt }
    }

    public var readyToSendSubmissions: [Submission] {
        submissions.filter { $0.status == .readyToSend }.sorted { $0.createdAt > $1.createdAt }
    }

    public var sentSubmissions: [Submission] {
        submissions.filter { $0.status == .sent }.sorted { ($0.sentAt ?? $0.createdAt) > ($1.sentAt ?? $1.createdAt) }
    }

    /// Persists a form's current instance XML as `status` (`.draft` for a mid-form
    /// checkpoint, `.readyToSend` for a fully answered form about to be uploaded),
    /// alongside a copy of the XForm XML it was filled in from and any media
    /// (photos, signatures, recordings, ...) the model's `binary` fields reference by
    /// filename. Pass `existingID` (the id of a `Submission` returned from an earlier
    /// `save`) to update that same entry in place instead of creating a new one —
    /// attachments from earlier saves are kept; only filenames present in
    /// `attachments` are (over)written. This is also how a `.draft` becomes
    /// `.readyToSend`: save again with the same `existingID` and `status: .readyToSend`.
    @discardableResult
    public func save(
        xml: String,
        xformXML: String,
        formID: String,
        formName: String,
        status: Status,
        attachments: [String: Data] = [:],
        existingID: String? = nil
    ) throws -> Submission {
        let id = existingID ?? UUID().uuidString
        let folder = folderURL(for: id)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try xml.write(to: folder.appendingPathComponent("submission.xml"), atomically: true, encoding: .utf8)
        try xformXML.write(to: folder.appendingPathComponent("form.xml"), atomically: true, encoding: .utf8)

        if !attachments.isEmpty {
            let attachmentsFolder = self.attachmentsFolderURL(for: id)
            try fileManager.createDirectory(at: attachmentsFolder, withIntermediateDirectories: true)
            for (filename, data) in attachments {
                try data.write(to: attachmentsFolder.appendingPathComponent(filename))
            }
        }

        let createdAt = existingID.flatMap { id in submissions.first(where: { $0.id == id })?.createdAt } ?? Date()
        let submission = Submission(id: id, formID: formID, formName: formName, createdAt: createdAt, status: status, sentAt: nil)
        try writeMeta(submission)

        if let index = submissions.firstIndex(where: { $0.id == id }) {
            submissions[index] = submission
        } else {
            submissions.append(submission)
        }
        return submission
    }

    /// The instance XML (the filled-in answers) for a submission.
    public func xmlData(for id: String) throws -> Data {
        try Data(contentsOf: folderURL(for: id).appendingPathComponent("submission.xml"))
    }

    /// The original XForm XML a `.draft`/`.readyToSend` entry was filled in from, so it can be
    /// reopened and resumed without re-downloading it.
    public func xformXML(for id: String) throws -> String {
        let data = try Data(contentsOf: folderURL(for: id).appendingPathComponent("form.xml"))
        return String(decoding: data, as: UTF8.self)
    }

    /// Filenames of every media attachment saved alongside a submission.
    public func attachmentFilenames(for id: String) -> [String] {
        (try? fileManager.contentsOfDirectory(atPath: attachmentsFolderURL(for: id).path)) ?? []
    }

    public func attachmentData(for id: String, filename: String) throws -> Data {
        try Data(contentsOf: attachmentsFolderURL(for: id).appendingPathComponent(filename))
    }

    /// Marks a submission `.sent` after its upload has succeeded.
    public func markSent(_ id: String) {
        guard let index = submissions.firstIndex(where: { $0.id == id }) else { return }
        submissions[index].status = .sent
        submissions[index].sentAt = Date()
        try? writeMeta(submissions[index])
    }

    /// Claims a submission for upload, returning `false` if it isn't currently
    /// `.readyToSend` or another send path already has it in flight. Callers must
    /// pair a successful claim with `endSending(_:)` once the attempt finishes
    /// (success or failure).
    public func beginSending(_ id: String) -> Bool {
        guard submissions.first(where: { $0.id == id })?.status == .readyToSend else { return false }
        return sendingIDs.insert(id).inserted
    }

    /// Releases a claim taken by `beginSending(_:)`.
    public func endSending(_ id: String) {
        sendingIDs.remove(id)
    }

    public func delete(_ id: String) throws {
        try fileManager.removeItem(at: folderURL(for: id))
        submissions.removeAll { $0.id == id }
    }

    private func folderURL(for id: String) -> URL {
        directory.appendingPathComponent(id, isDirectory: true)
    }

    private func attachmentsFolderURL(for id: String) -> URL {
        folderURL(for: id).appendingPathComponent("attachments", isDirectory: true)
    }

    private func writeMeta(_ submission: Submission) throws {
        let data = try Self.encoder.encode(submission)
        try data.write(to: folderURL(for: submission.id).appendingPathComponent("meta.json"))
    }

    private func reload() {
        guard let folders = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        submissions = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")) else { return nil }
            guard let submission = try? Self.decoder.decode(Submission.self, from: data) else { return nil }
            // Both files are written together in `save` — but skip anything missing
            // either (e.g. left over from a build predating the `form.xml` copy)
            // rather than surface an entry that will fail to open.
            let hasInstanceXML = fileManager.fileExists(atPath: folder.appendingPathComponent("submission.xml").path)
            let hasFormXML = fileManager.fileExists(atPath: folder.appendingPathComponent("form.xml").path)
            guard hasInstanceXML && hasFormXML else { return nil }
            return submission
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
