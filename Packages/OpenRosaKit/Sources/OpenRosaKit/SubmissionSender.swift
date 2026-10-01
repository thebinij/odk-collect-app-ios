import Foundation

/// The one place a `.readyToSend` submission is actually uploaded: reads the
/// instance XML and its media attachments back off disk, confirms credentials
/// against `/submission` (`HEAD`), POSTs the multipart body, and marks the entry
/// `.sent` on success.
///
/// Shared by every send path — the manual **Send Now** row, the form flow's inline
/// attempt right after **Send**, and `AutoSendCoordinator`'s background sweeps — so
/// they can't drift apart. Every path saves locally *first*; this only runs once an
/// entry is already `.readyToSend`.
public struct SubmissionSender {
    private let submissionStore: SubmissionStore
    private let client: OpenRosaClient

    public init(serverURL: URL, username: String, password: String, submissionStore: SubmissionStore) {
        self.submissionStore = submissionStore
        self.client = OpenRosaClient(serverURL: serverURL, username: username, password: password)
    }

    /// Uploads `submission`. Returns `false` (without touching the network) when it
    /// isn't currently `.readyToSend` or another send path already has it in
    /// flight — a manual tap and an automatic sweep must never upload the same
    /// submission twice. Throws whatever `OpenRosaClient` throws on a real attempt;
    /// the submission simply stays `.readyToSend`.
    @discardableResult
    public func send(_ submission: SubmissionStore.Submission) async throws -> Bool {
        guard submissionStore.beginSending(submission.id) else { return false }
        defer { submissionStore.endSending(submission.id) }

        let xml = try submissionStore.xmlData(for: submission.id)
        // A submission's instance XML references every attachment by filename in its
        // own `<upload>` fields — silently sending without one that failed to read
        // would upload a record the server (and the user) believe is complete but
        // is permanently missing a photo/signature/recording. Fail the whole send
        // instead, so the submission stays `.readyToSend` and can be retried.
        let attachments = try submissionStore.attachmentFilenames(for: submission.id).map { filename -> SubmissionAttachment in
            let data = try submissionStore.attachmentData(for: submission.id, filename: filename)
            return SubmissionAttachment(
                filename: filename,
                contentType: SubmissionAttachment.contentType(forFilename: filename),
                data: data
            )
        }

        try await client.probeSubmission()
        try await client.submit(xml: xml, attachments: attachments)
        submissionStore.markSent(submission.id)
        return true
    }
}
