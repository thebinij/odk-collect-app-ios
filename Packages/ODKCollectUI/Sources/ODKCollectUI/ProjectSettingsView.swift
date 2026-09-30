import OpenRosaKit
import ProjectSettingsKit
import SwiftUI

/// Server URL + credentials. Fields bind straight to `ProjectStore` and persist as
/// you type — there's no separate Save action.
public struct ProjectSettingsView: View {
    @ObservedObject private var projectStore: ProjectStore

    @State private var isTestingConnection = false
    @State private var testConnectionMessage: String?
    @State private var testConnectionSucceeded = false

    public init(projectStore: ProjectStore) {
        self.projectStore = projectStore
    }

    public var body: some View {
        Form {
            Section("Server") {
                TextField("https://your-odk-server.example.org", text: $projectStore.serverURLText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Username", text: $projectStore.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $projectStore.password)

                Button {
                    Task { await testConnection() }
                } label: {
                    if isTestingConnection {
                        ProgressView()
                    } else {
                        Text("Test Connection")
                    }
                }
                .disabled(isTestingConnection)

                if let testConnectionMessage {
                    Text(testConnectionMessage)
                        .font(.footnote)
                        .foregroundStyle(testConnectionSucceeded ? .green : .red)
                }
            }
        }
        .navigationTitle("Project Settings")
    }

    private func testConnection() async {
        isTestingConnection = true
        testConnectionMessage = nil
        defer { isTestingConnection = false }

        guard let project = projectStore.project else {
            testConnectionSucceeded = false
            testConnectionMessage = "Enter a valid server URL and username first."
            return
        }

        let client = OpenRosaClient(
            serverURL: project.serverURL,
            username: project.username,
            password: projectStore.password
        )
        do {
            let forms = try await client.fetchFormList()
            testConnectionSucceeded = true
            testConnectionMessage = "Connected — found \(forms.count) form\(forms.count == 1 ? "" : "s")."
        } catch {
            testConnectionSucceeded = false
            testConnectionMessage = error.localizedDescription
        }
    }
}
