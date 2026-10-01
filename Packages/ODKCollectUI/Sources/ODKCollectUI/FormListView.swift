import OpenRosaKit
import ProjectSettingsKit
import SwiftUI

private struct DownloadedForm: Identifiable {
    let id: String
    let name: String
    let xml: String
}

/// Lists forms discovered via the OpenRosa `formList` call for the active project.
/// Every form's XForm XML is downloaded and cached automatically in the background
/// as soon as the list loads — not only once a user taps into it — so the whole set
/// is available offline right away, the same way ODK Collect's own "Get Blank Form"
/// sync works. Tapping a form still independently tries a live fetch first (picking
/// up any update instantly rather than waiting on the background sync), falling back
/// to the cache if there's no connection.
///
/// Both the list itself and each form's XML are cached locally (`FormCacheStore`) —
/// a live fetch always wins when there's connectivity (and refreshes the cache), but
/// with no connection this falls back to whatever was cached from the last
/// successful sync, so a form already seen once stays usable indefinitely offline.
public struct FormListView: View {
    private let project: Project
    private let password: String
    private let submissionStore: SubmissionStore
    private let formCacheStore = FormCacheStore()

    @State private var forms: [RemoteForm] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isShowingCachedForms = false
    @State private var syncProgress: (done: Int, total: Int)?
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
            .navigationBarTitleDisplayMode(.inline)
            .task { await loadForms() }
            .fullScreenCover(item: $downloadedForm) { downloaded in
                EnketoFormContainerView(
                    formID: downloaded.id,
                    formName: downloaded.name,
                    xformXML: downloaded.xml,
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
                VStack(spacing: 0) {
                    if isShowingCachedForms {
                        Label("Offline — showing forms from your last sync", systemImage: "wifi.slash")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(8)
                            .background(.background.opacity(0.95))
                    } else if let syncProgress {
                        Label("Downloading forms for offline use\u{2026} \(syncProgress.done)/\(syncProgress.total)", systemImage: "arrow.down.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(8)
                            .background(.background.opacity(0.95))
                    }

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
                                if let downloadedAt = formCacheStore.cachedFormDownloadDate(formID: form.formID) {
                                    Text("Downloaded \(Self.downloadedAtFormatter.string(from: downloadedAt))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    .refreshable { await loadForms() }
                    .disabled(isDownloadingForm)
                }

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
            let result = try await OfflineFallback.resolve(
                primary: { try await client.fetchFormList() },
                cached: { formCacheStore.cachedFormList() }
            )
            forms = result.value
            isShowingCachedForms = result.source == .cached
            if result.source == .live {
                formCacheStore.cacheFormList(result.value)
                // Fire-and-forget: the list itself must appear (and stay tappable)
                // immediately — it must not wait on every form finishing download.
                Task { await syncAllFormXML(result.value, client: client) }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Downloads and caches every form not already cached, so the whole list is
    /// usable offline right away rather than only whichever forms happen to get
    /// tapped first. Best-effort: one form failing to download (e.g. a flaky
    /// connection partway through) is silently skipped rather than surfaced as an
    /// error — `open(form:)` will simply try that form live again when it's tapped.
    private func syncAllFormXML(_ forms: [RemoteForm], client: OpenRosaClient) async {
        let toDownload = forms.filter { formCacheStore.cachedFormXML(formID: $0.formID) == nil }
        guard !toDownload.isEmpty else { return }

        syncProgress = (done: 0, total: toDownload.count)
        defer { syncProgress = nil }

        for (index, form) in toDownload.enumerated() {
            if let data = try? await client.fetchFormXML(from: form.downloadURL) {
                formCacheStore.cacheFormXML(String(decoding: data, as: UTF8.self), formID: form.formID)
            }
            syncProgress = (done: index + 1, total: toDownload.count)
        }
    }

    private func open(_ form: RemoteForm) {
        Task {
            isDownloadingForm = true
            defer { isDownloadingForm = false }
            let client = OpenRosaClient(serverURL: project.serverURL, username: project.username, password: password)
            do {
                let result = try await OfflineFallback.resolve(
                    primary: { try await client.fetchFormXML(from: form.downloadURL) },
                    cached: { formCacheStore.cachedFormXML(formID: form.formID).map { Data($0.utf8) } }
                )
                let xml = String(decoding: result.value, as: UTF8.self)
                if result.source == .live {
                    formCacheStore.cacheFormXML(xml, formID: form.formID)
                }
                downloadedForm = DownloadedForm(id: form.formID, name: form.name, xml: xml)
            } catch {
                formErrorMessage = error.localizedDescription
            }
        }
    }

    /// Fixed `yyyy-MM-dd HH:mm:ss` layout regardless of locale (so it reads the same
    /// for every user), but in the device's own current time zone/calendar — a
    /// download timestamp should read as "when that happened for me," not UTC.
    private static let downloadedAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
