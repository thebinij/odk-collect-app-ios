import OpenRosaKit
import ProjectSettingsKit

/// One bounded, best-effort Auto Send pass with no SwiftUI view hierarchy — the
/// entry point a `BGAppRefreshTask` handler calls. Unlike `AutoSendCoordinator`
/// (a long-lived reactive subscription tied to a running UI), a background task
/// fires independently of whether any UI was ever created for this launch, and
/// gets one short, bounded window rather than an ongoing session — so this reads
/// stores fresh, takes one connectivity snapshot, and makes a single pass.
public enum BackgroundSendRunner {
    public static func run(
        projectStore: ProjectStore = ProjectStore(),
        settings: FormSubmissionSettingsStore = FormSubmissionSettingsStore(),
        submissionStore: SubmissionStore = SubmissionStore()
    ) async {
        guard settings.autoSend != .off else { return }
        guard let project = projectStore.project else { return }

        let snapshot = await ConnectivityMonitor.currentSnapshot()
        guard settings.autoSend.isEligible(
            isOnline: snapshot.isOnline,
            isOnWiFi: snapshot.isOnWiFi,
            isOnCellular: snapshot.isOnCellular
        ) else { return }

        let sender = SubmissionSender(
            serverURL: project.serverURL,
            username: project.username,
            password: projectStore.password,
            submissionStore: submissionStore
        )
        for submission in submissionStore.readyToSendSubmissions {
            // Silent and best-effort, same contract as `AutoSendCoordinator`: a
            // failure just leaves the submission `.readyToSend` for the next
            // foreground or background attempt, rather than failing the whole run.
            _ = try? await sender.send(submission)
        }
    }
}
