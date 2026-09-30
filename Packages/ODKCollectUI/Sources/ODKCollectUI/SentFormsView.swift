import OpenRosaKit
import SwiftUI

/// Lists forms that have been successfully uploaded, most recent first. Tapping one
/// shows every answer read-only, all on one page (see `SentFormAnswersView`) — sent
/// forms are done, so there's no editing option.
public struct SentFormsView: View {
    @ObservedObject private var submissionStore: SubmissionStore

    public init(submissionStore: SubmissionStore) {
        self.submissionStore = submissionStore
    }

    public var body: some View {
        Group {
            if submissionStore.sentSubmissions.isEmpty {
                Text("No sent forms yet.")
                    .foregroundStyle(.secondary)
            } else {
                List(submissionStore.sentSubmissions) { submission in
                    NavigationLink {
                        SentFormAnswersView(submission: submission, submissionStore: submissionStore)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(submission.formName)
                            if let sentAt = submission.sentAt {
                                Text(sentAt, format: .dateTime)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Sent Forms")
        .navigationBarTitleDisplayMode(.inline)
    }
}
