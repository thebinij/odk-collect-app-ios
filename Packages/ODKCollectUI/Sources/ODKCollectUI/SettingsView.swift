import ProjectSettingsKit
import SwiftUI

/// Top-level settings list, pushed (not presented as a sheet) from the gear icon on
/// `RootView`. Holds "Server Settings" and "Form Management"; future settings
/// sections get added here as additional rows.
public struct SettingsView: View {
    @ObservedObject private var projectStore: ProjectStore
    @ObservedObject private var formSubmissionSettingsStore: FormSubmissionSettingsStore

    public init(projectStore: ProjectStore, formSubmissionSettingsStore: FormSubmissionSettingsStore) {
        self.projectStore = projectStore
        self.formSubmissionSettingsStore = formSubmissionSettingsStore
    }

    public var body: some View {
        List {
            NavigationLink("Server Settings") {
                ServerSettingsView(projectStore: projectStore)
            }
            NavigationLink("Form Management") {
                FormManagementView(settings: formSubmissionSettingsStore)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
