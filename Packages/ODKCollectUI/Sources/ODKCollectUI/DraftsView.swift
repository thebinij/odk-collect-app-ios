import OpenRosaKit
import ProjectSettingsKit
import SwiftUI

private struct OpenedDraft: Identifiable {
    let id: String
    let formID: String
    let formName: String
    let xformXML: String
    let instanceXML: String
}

/// Lists forms that have been saved (mid-fill, or a completed submission that
/// couldn't reach the server yet) but not sent. Tapping one reopens it in the normal
/// one-question-at-a-time flow, starting from the first question regardless of what's
/// already answered — the form's own XForm definition was saved alongside the
/// answers, so this works fully offline.
public struct DraftsView: View {
    private let project: Project
    private let password: String
    @ObservedObject private var submissionStore: SubmissionStore

    @State private var openedDraft: OpenedDraft?
    @State private var isLoadingDraft = false
    @State private var loadErrorMessage: String?

    public init(project: Project, password: String, submissionStore: SubmissionStore) {
        self.project = project
        self.password = password
        self.submissionStore = submissionStore
    }

    public var body: some View {
        ZStack {
            if submissionStore.pendingSubmissions.isEmpty {
                Text("No drafts.")
                    .foregroundStyle(.secondary)
            } else {
                List(submissionStore.pendingSubmissions) { submission in
                    Button {
                        open(submission)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(submission.formName)
                            Text(submission.createdAt, format: .dateTime)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .disabled(isLoadingDraft)
            }

            if isLoadingDraft {
                ProgressView()
                    .padding()
                    .background(.background.opacity(0.95))
            }
        }
        .navigationTitle("Drafts")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $openedDraft) { draft in
            EnketoFormContainerView(
                formID: draft.formID,
                formName: draft.formName,
                xformXML: draft.xformXML,
                instanceXML: draft.instanceXML,
                existingSubmissionID: draft.id,
                project: project,
                password: password,
                submissionStore: submissionStore
            ) {
                openedDraft = nil
            }
        }
        .alert(
            "Can't Open Draft",
            isPresented: Binding(
                get: { loadErrorMessage != nil },
                set: { isPresented in if !isPresented { loadErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(loadErrorMessage ?? "")
        }
    }

    private func open(_ submission: SubmissionStore.Submission) {
        isLoadingDraft = true
        defer { isLoadingDraft = false }
        do {
            let xformXML = try submissionStore.xformXML(for: submission.id)
            let instanceXML = try submissionStore.xmlData(for: submission.id)
            openedDraft = OpenedDraft(
                id: submission.id,
                formID: submission.formID,
                formName: submission.formName,
                xformXML: xformXML,
                instanceXML: String(decoding: instanceXML, as: UTF8.self)
            )
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }
}
