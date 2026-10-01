import BackgroundTasks
import ODKCollectUI
import ProjectSettingsKit
import UIKit

/// Registers and schedules the Auto Send background refresh task. A plain
/// `UIApplicationDelegate` (via `@UIApplicationDelegateAdaptor`) rather than
/// SwiftUI's `.backgroundTask(.appRefresh:)` scene modifier, since that API needs
/// iOS 17 and this app's floor is 16.4 (see README's "Known limitations").
///
/// `BGTaskScheduler` only ever grants an *opportunity* to run, on its own
/// schedule, based on the system's own judgment of device/battery/usage
/// conditions — there is no way for a third-party app to guarantee background
/// execution on iOS, with or without this framework.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static let autoSendTaskIdentifier = "np.com.yipl.odk.autosend"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Must be registered before `didFinishLaunching` returns, whether or not
        // this particular launch is the user opening the app or the system
        // waking it to run the task itself.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.autoSendTaskIdentifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            Self.handle(task)
        }
        return true
    }

    /// Requests the next opportunity to run, if Auto Send is even turned on —
    /// scheduling one otherwise would just spend one of the system's limited
    /// background opportunities on a task that immediately no-ops.
    func applicationDidEnterBackground(_ application: UIApplication) {
        guard FormSubmissionSettingsStore().autoSend != .off else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.autoSendTaskIdentifier)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        // Always queue the next opportunity before this one even runs — win or
        // lose this attempt, Auto Send still needs a next chance while the app
        // stays backgrounded.
        let request = BGAppRefreshTaskRequest(identifier: autoSendTaskIdentifier)
        try? BGTaskScheduler.shared.submit(request)

        let work = Task {
            await BackgroundSendRunner.run()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}
