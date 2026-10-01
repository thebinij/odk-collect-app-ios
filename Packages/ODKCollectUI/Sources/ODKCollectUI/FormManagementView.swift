import ProjectSettingsKit
import SwiftUI

/// Form-related settings. Currently one section, "Form Submission", holding the
/// **Auto Send** setting — whether, and over what kind of connection, a fully
/// answered form uploads on its own once it's `.readyToSend`. Persisted the
/// moment an option is picked (no separate Save step), matching
/// `ServerSettingsView`'s plain `Form` look.
public struct FormManagementView: View {
    @ObservedObject private var settings: FormSubmissionSettingsStore

    public init(settings: FormSubmissionSettingsStore) {
        self.settings = settings
    }

    public var body: some View {
        Form {
            Section {
                Picker("Auto Send", selection: $settings.autoSend) {
                    Text("Off").tag(AutoSendMode.off)
                    Text("Wi-Fi only").tag(AutoSendMode.wifiOnly)
                    Text("Cellular only").tag(AutoSendMode.cellularOnly)
                    Text("Wi-Fi or Cellular").tag(AutoSendMode.wifiOrCellular)
                }
            } header: {
                Text("Form Submission")
            } footer: {
                Text(footer)
            }
        }
        .navigationTitle("Form Management")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var footer: String {
        switch settings.autoSend {
        case .off:
            return "Sent forms wait in Ready to Send until you tap Send Now."
        case .wifiOnly:
            return "Sent forms upload automatically, but only while connected to Wi-Fi."
        case .cellularOnly:
            return "Sent forms upload automatically over cellular data. Connect to Wi-Fi to avoid using cellular data."
        case .wifiOrCellular:
            return "Sent forms upload automatically as soon as you're online, over Wi-Fi or cellular."
        }
    }
}
