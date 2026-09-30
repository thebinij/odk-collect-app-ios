import Foundation

/// Local, on-disk queue of filled-in forms: every save — whether an explicit mid-form
/// "Save Draft" or the auto-save that happens right before a submit attempt — is
/// persisted here as `.pending` first, so nothing is lost without a network
/// connection. A `.pending` entry is later either updated in place (further edits to
/// the same draft) or marked `.sent` once its `OpenRosaClient.submit` upload succeeds.
///
/// Each submission also keeps a copy of the form's own XForm XML alongside the
/// instance data, so a `.pending` draft can be reopened and resumed entirely offline
/// — no need to re-download the form definition.
public final class SubmissionStore: ObservableObject {
    public enum Status: String, Codable {
        case pending
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

    public var pendingSubmissions: [Submission] {
        submissions.filter { $0.status == .pending }.sorted { $0.createdAt > $1.createdAt }
    }

    public var sentSubmissions: [Submission] {
        submissions.filter { $0.status == .sent }.sorted { ($0.sentAt ?? $0.createdAt) > ($1.sentAt ?? $1.createdAt) }
    }

    /// Persists a form's current instance XML (complete or still in progress) as
    /// `.pending`, alongside a copy of the XForm XML it was filled in from and any
    /// media (photos, signatures, recordings, ...) the model's `binary` fields
    /// reference by filename. Pass `existingID` (the id of a `Submission` returned
    /// from an earlier `save`) to update that same draft in place instead of creating
    /// a new one — attachments from earlier saves are kept; only filenames present in
    /// `attachments` are (over)written.
    @discardableResult
    public func save(
        xml: String,
        xformXML: String,
        formID: String,
        formName: String,
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
        let submission = Submission(id: id, formID: formID, formName: formName, createdAt: createdAt, status: .pending, sentAt: nil)
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

    /// The original XForm XML a `.pending` draft was filled in from, so it can be
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
