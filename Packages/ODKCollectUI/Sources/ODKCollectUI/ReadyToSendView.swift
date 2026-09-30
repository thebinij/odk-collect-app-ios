import OpenRosaKit
import ProjectSettingsKit
import SwiftUI

/// Lists forms that have been fully answered ("Send" was tapped) but haven't
/// actually reached the server yet — almost always because there was no network at
/// that moment. Each has its own "Send Now" retry; for now that's the only way one
/// leaves this list (a Settings toggle for automatic retry-when-online is planned,
/// not yet built), so nothing here is ever silently lost or silently sent without
/// the user asking for it.
public struct ReadyToSendView: View {
    private let project: Project
    private let password: String
    @ObservedObject private var submissionStore: SubmissionStore

    @State private var sendingID: String?
    @State private var errorMessage: String?

    public init(project: Project, password: String, submissionStore: SubmissionStore) {
        self.project = project
        self.password = password
        self.submissionStore = submissionStore
    }

    public var body: some View {
        ZStack {
            if submissionStore.readyToSendSubmissions.isEmpty {
                Text("Nothing waiting to send.")
                    .foregroundStyle(.secondary)
            } else {
                List(submissionStore.readyToSendSubmissions) { submission in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(submission.formName)
                            Text(submission.createdAt, format: .dateTime)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            Task { await send(submission) }
                        } label: {
                            if sendingID == submission.id {
                                ProgressView()
                            } else {
                                Image(systemName: "paperplane.fill")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(sendingID != nil)
                    }
                }
            }
        }
        .navigationTitle("Ready to Send")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "Couldn't Send",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in if !isPresented { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func send(_ submission: SubmissionStore.Submission) async {
        sendingID = submission.id
        defer { sendingID = nil }

        do {
            let xml = try submissionStore.xmlData(for: submission.id)
            let attachments = submissionStore.attachmentFilenames(for: submission.id).compactMap { filename -> SubmissionAttachment? in
                guard let data = try? submissionStore.attachmentData(for: submission.id, filename: filename) else { return nil }
                return SubmissionAttachment(filename: filename, contentType: SubmissionAttachment.contentType(forFilename: filename), data: data)
            }

            let client = OpenRosaClient(serverURL: project.serverURL, username: project.username, password: password)
            try await client.probeSubmission()
            try await client.submit(xml: xml, attachments: attachments)
            submissionStore.markSent(submission.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
