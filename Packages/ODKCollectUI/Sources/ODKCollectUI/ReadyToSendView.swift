import OpenRosaKit
import ProjectSettingsKit
import SwiftUI

/// Lists forms that have been fully answered ("Send" was tapped) but haven't
/// actually reached the server yet — almost always because there was no network at
/// that moment. Each has its own "Send Now" retry. With **Auto Send** set to
/// anything other than Off (Form Management → Form Submission), the app also
/// retries these on its own once a matching connection is available (see
/// `AutoSendCoordinator`), but the manual button always remains available;
/// nothing here is ever silently lost.
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

        let sender = SubmissionSender(
            serverURL: project.serverURL,
            username: project.username,
            password: password,
            submissionStore: submissionStore
        )
        do {
            try await sender.send(submission)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
