import ProjectSettingsKit
import SwiftUI

/// Top-level settings list, pushed (not presented as a sheet) from the gear icon on
/// `RootView`. Currently holds just "Project Settings"; future settings sections get
/// added here as additional rows.
public struct SettingsView: View {
    @ObservedObject private var projectStore: ProjectStore

    public init(projectStore: ProjectStore) {
        self.projectStore = projectStore
    }

    public var body: some View {
        List {
            NavigationLink("Project Settings") {
                ProjectSettingsView(projectStore: projectStore)
            }
        }
        .navigationTitle("Settings")
    }
}
