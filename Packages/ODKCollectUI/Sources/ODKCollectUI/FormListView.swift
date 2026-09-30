import OpenRosaKit
import ProjectSettingsKit
import SwiftUI

private struct DownloadedForm: Identifiable {
    let id: String
    let name: String
    let xml: String
}

/// Lists forms discovered via the OpenRosa `formList` call for the active project.
/// Tapping a form downloads its raw XForm XML (`GET` the form's `downloadUrl`, e.g.
/// `forms/{id}/form.xml`) and opens it in the bundled Enketo engine.
public struct FormListView: View {
    private let project: Project
    private let password: String
    private let submissionStore: SubmissionStore

    @State private var forms: [RemoteForm] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var downloadedForm: DownloadedForm?
    @State private var isDownloadingForm = false
    @State private var formErrorMessage: String?

    public init(project: Project, password: String, submissionStore: SubmissionStore) {
        self.project = project
        self.password = password
        self.submissionStore = submissionStore
    }

    public var body: some View {
        content
            .navigationTitle("Forms")
            .task { await loadForms() }
            .fullScreenCover(item: $downloadedForm) { downloaded in
                EnketoFormContainerView(
                    formID: downloaded.id,
                    formName: downloaded.name,
                    xformXML: downloaded.xml,
                    project: project,
                    password: password,
                    submissionStore: submissionStore
                ) {
                    downloadedForm = nil
                }
            }
            .alert(
                "Can't Open Form",
                isPresented: Binding(
                    get: { formErrorMessage != nil },
                    set: { isPresented in if !isPresented { formErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(formErrorMessage ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && forms.isEmpty {
            ProgressView("Loading forms\u{2026}")
        } else if let loadError, forms.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(loadError)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                Button("Retry") { Task { await loadForms() } }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        } else if forms.isEmpty {
            Text("No forms available.")
                .foregroundStyle(.secondary)
        } else {
            ZStack {
                List(forms) { form in
                    Button {
                        open(form)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(form.name)
                            if let version = form.version {
                                Text("Version \(version)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .refreshable { await loadForms() }
                .disabled(isDownloadingForm)

                if isDownloadingForm {
                    ProgressView("Downloading form\u{2026}")
                        .padding()
                        .background(.background.opacity(0.95))
                }
            }
        }
    }

    private func loadForms() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        let client = OpenRosaClient(serverURL: project.serverURL, username: project.username, password: password)
        do {
            forms = try await client.fetchFormList()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func open(_ form: RemoteForm) {
        Task {
            isDownloadingForm = true
            defer { isDownloadingForm = false }
            let client = OpenRosaClient(serverURL: project.serverURL, username: project.username, password: password)
            do {
                let data = try await client.fetchFormXML(from: form.downloadURL)
                downloadedForm = DownloadedForm(id: form.formID, name: form.name, xml: String(decoding: data, as: UTF8.self))
            } catch {
                formErrorMessage = error.localizedDescription
            }
        }
    }
}
