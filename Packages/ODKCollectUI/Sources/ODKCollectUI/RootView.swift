import OpenRosaKit
import ProjectSettingsKit
import SwiftUI

/// Home screen: a full-width "+ Start new form" button at the top — always enabled;
/// tapping it with no project configured prompts to set one up instead of navigating —
/// leading into `FormListView`, then "Drafts" and "Sent Forms" buttons below it, plus a
/// top-right gear icon pushing `SettingsView` — the settings list that currently holds
/// just "Project Settings".
///
/// Saving or submitting a form always writes it locally first via `SubmissionStore`
/// (as `.pending`) — a mid-fill "Save" checkpoints progress to resume later from
/// Drafts, and Submit additionally tries to upload right away, marking it `.sent` on
/// success. Nothing is lost without a connection.
public struct RootView: View {
    @StateObject private var projectStore: ProjectStore
    @StateObject private var submissionStore = SubmissionStore()
    @State private var isShowingNoProjectAlert = false
    @State private var isShowingFormList = false

    public init(projectStore: @autoclosure @escaping () -> ProjectStore = ProjectStore()) {
        _projectStore = StateObject(wrappedValue: projectStore())
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Button {
                    if projectStore.project != nil {
                        isShowingFormList = true
                    } else {
                        isShowingNoProjectAlert = true
                    }
                } label: {
                    Text("+ Start new form")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
                .background(
                    Group {
                        if let project = projectStore.project {
                            NavigationLink(isActive: $isShowingFormList) {
                                FormListView(project: project, password: projectStore.password, submissionStore: submissionStore)
                            } label: { EmptyView() }
                        }
                    }
                    .hidden()
                )
                .alert("No Project Configured", isPresented: $isShowingNoProjectAlert) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Set up Project Settings first.")
                }

                if let project = projectStore.project {
                    NavigationLink {
                        DraftsView(project: project, password: projectStore.password, submissionStore: submissionStore)
                    } label: {
                        Text("Drafts")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .padding(.horizontal)
                }

                NavigationLink {
                    SentFormsView(submissionStore: submissionStore)
                } label: {
                    Text("Sent Forms")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top)
            .navigationTitle("ODK Collect")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        SettingsView(projectStore: projectStore)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
    }
}
