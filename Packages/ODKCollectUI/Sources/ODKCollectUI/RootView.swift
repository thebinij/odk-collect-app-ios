import ODKWebEngine
import OpenRosaKit
import ProjectSettingsKit
import SwiftUI

/// Home screen: a full-width "+ Start new form" button at the top — always enabled;
/// tapping it with no project configured prompts to set one up instead of navigating —
/// leading into `FormListView`, then "Drafts", "Ready to Send", and "Sent Forms"
/// buttons below it, plus a top-right gear icon pushing `SettingsView` — the settings
/// list that holds "Server Settings" and "Form Management" (Auto Send: Off / Wi-Fi
/// only / Cellular only / Wi-Fi or Cellular).
///
/// Saving or submitting a form always writes it locally first via `SubmissionStore`:
/// a mid-fill "Save" checkpoints progress as `.draft` to resume later from Drafts, and
/// "Send" saves as `.readyToSend` before attempting the upload, marking it `.sent` on
/// success — if that upload fails (most commonly: no network), it simply stays
/// `.readyToSend`, visible in Ready to Send for a manual retry. Nothing is lost
/// without a connection.
public struct RootView: View {
    @StateObject private var projectStore: ProjectStore
    @StateObject private var formSubmissionSettingsStore: FormSubmissionSettingsStore
    @StateObject private var submissionStore: SubmissionStore
    @StateObject private var connectivity: ConnectivityMonitor
    @StateObject private var autoSendCoordinator: AutoSendCoordinator
    // Absorbs WebKit's one-time "cold start" cost — creating the very first
    // `WKWebView` in the process spins up a whole WebContent process and JIT-warms
    // its JS engine, measured at ~9s (vs ~0.7s for every load after the first,
    // since the underlying process/engine stays warm for the app's lifetime once
    // created). Loading a trivial, throwaway form here absorbs that cost silently
    // in the background as soon as Home appears — while the user has nothing to
    // wait on yet — rather than the first tap into a draft, a sent submission, or
    // a new form paying it synchronously. The engine's own rendered HTML is never
    // shown for any of this app's forms, so this one is invisible exactly like
    // every other — see `EnketoFormContainerView`/`SentFormAnswersView`.
    @StateObject private var enginePrewarmState = EnketoFormState()
    @State private var isShowingNoProjectAlert = false
    @State private var isShowingFormList = false

    public init(
        projectStore: @autoclosure @escaping () -> ProjectStore = ProjectStore(),
        formSubmissionSettingsStore: @autoclosure @escaping () -> FormSubmissionSettingsStore = FormSubmissionSettingsStore(),
        submissionStore: @autoclosure @escaping () -> SubmissionStore = SubmissionStore(),
        connectivity: @autoclosure @escaping () -> ConnectivityMonitor = ConnectivityMonitor()
    ) {
        let projectStore = projectStore()
        let formSubmissionSettingsStore = formSubmissionSettingsStore()
        let submissionStore = submissionStore()
        let connectivity = connectivity()

        _projectStore = StateObject(wrappedValue: projectStore)
        _formSubmissionSettingsStore = StateObject(wrappedValue: formSubmissionSettingsStore)
        _submissionStore = StateObject(wrappedValue: submissionStore)
        _connectivity = StateObject(wrappedValue: connectivity)
        _autoSendCoordinator = StateObject(wrappedValue: AutoSendCoordinator(
            settings: formSubmissionSettingsStore,
            connectivity: connectivity,
            submissionStore: submissionStore,
            projectProvider: { projectStore.project },
            passwordProvider: { projectStore.password },
            send: { submission, project, password in
                let sender = SubmissionSender(
                    serverURL: project.serverURL,
                    username: project.username,
                    password: password,
                    submissionStore: submissionStore
                )
                _ = try await sender.send(submission)
            }
        ))
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                EnketoFormView(xformXML: Self.prewarmFormXML, state: enginePrewarmState)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)

                homeContent
            }
            .navigationTitle("ODK Collect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        SettingsView(projectStore: projectStore, formSubmissionSettingsStore: formSubmissionSettingsStore)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .onAppear {
                connectivity.start()
                autoSendCoordinator.start()
            }
        }
    }

    private var homeContent: some View {
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
            .navigationDestination(isPresented: $isShowingFormList) {
                if let project = projectStore.project {
                    FormListView(project: project, password: projectStore.password, submissionStore: submissionStore)
                }
            }
            .alert("No Project Configured", isPresented: $isShowingNoProjectAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Set up Server Settings first.")
            }

            if let project = projectStore.project {
                NavigationLink {
                    DraftsView(submissionStore: submissionStore)
                } label: {
                    Text("Drafts")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.horizontal)

                NavigationLink {
                    ReadyToSendView(project: project, password: projectStore.password, submissionStore: submissionStore)
                } label: {
                    Text("Ready to Send")
                        .font(.headline)
                        // Bold signals there's something waiting to go out — matches
                        // the "nothing is ever silently lost" guarantee this screen
                        // gives for submissions stuck here (usually just no network).
                        .fontWeight(submissionStore.readyToSendSubmissions.isEmpty ? nil : .bold)
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

            if let appVersionText {
                Text(appVersionText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }

            Spacer()
        }
        .padding(.top)
    }

    private var appVersionText: String? {
        guard
            let info = Bundle.main.infoDictionary,
            let version = info["CFBundleShortVersionString"] as? String,
            let build = info["CFBundleVersion"] as? String
        else { return nil }
        return "Version \(version) (\(build))"
    }

    /// A minimal, valid XForm with nothing to answer — exists purely to give
    /// WebKit something to load so its one-time cold-start cost (see
    /// `enginePrewarmState` above) happens now, in the background, rather than
    /// blocking the first real form/draft/submission the user opens.
    private static let prewarmFormXML = """
    <?xml version="1.0"?>
    <h:html xmlns="http://www.w3.org/2002/xforms" xmlns:h="http://www.w3.org/1999/xhtml" xmlns:jr="http://openrosa.org/javarosa">
      <h:head><h:title>Warm</h:title>
        <model>
          <instance><data id="warm"><a/></data></instance>
          <bind nodeset="/data/a" type="string"/>
        </model>
      </h:head>
      <h:body><input ref="/data/a"><label>a</label></input></h:body>
    </h:html>
    """
}
