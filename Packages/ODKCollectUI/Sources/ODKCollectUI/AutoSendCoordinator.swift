import Combine
import Foundation
import OpenRosaKit
import ProjectSettingsKit
import UIKit

/// Wires the **Auto Send** setting to the moments when a send should happen on
/// its own, with no tap ("send when"): coming online over a matching connection,
/// returning to the foreground while already on a matching connection, a new
/// submission becoming `.readyToSend` while already on a matching connection,
/// and the setting being switched to something other than Off. When
/// `autoSend == .off`, every trigger is a no-op — nothing leaves Ready to Send
/// without an explicit **Send Now**, exactly as before this feature existed.
///
/// Automatic attempts are silent: a success just moves the row to Sent, a
/// failure leaves it `.readyToSend` for the next trigger (logged, not alerted).
/// Sends run one at a time, in order.
@MainActor
public final class AutoSendCoordinator: ObservableObject {
    /// Uploads one submission using the given credentials. Injected so tests can
    /// observe/control attempts without a network round-trip. Production builds it
    /// from `SubmissionSender`.
    public typealias Send = (SubmissionStore.Submission, Project, String) async throws -> Void

    private let settings: FormSubmissionSettingsStore
    private let connectivity: ConnectivityMonitoring
    private let submissionStore: SubmissionStore
    private let projectProvider: () -> Project?
    private let passwordProvider: () -> String
    private let send: Send

    private var cancellables = Set<AnyCancellable>()
    private var hasStarted = false
    /// Set synchronously the moment a sweep is scheduled (before its `Task` gets to
    /// run), so a burst of triggers collapses into a single sweep instead of one
    /// task per trigger.
    private var isSweepScheduled = false
    private var isSweeping = false
    private var sweepAgain = false

    public init(
        settings: FormSubmissionSettingsStore,
        connectivity: ConnectivityMonitoring,
        submissionStore: SubmissionStore,
        projectProvider: @escaping () -> Project?,
        passwordProvider: @escaping () -> String,
        send: @escaping Send
    ) {
        self.settings = settings
        self.connectivity = connectivity
        self.submissionStore = submissionStore
        self.projectProvider = projectProvider
        self.passwordProvider = passwordProvider
        self.send = send
    }

    /// Subscribes to every trigger. Subscriptions are always installed (so a later
    /// switch away from `.off` is noticed), but each callback checks the mode/
    /// connectivity first, so with Auto Send Off nothing else here ever runs.
    /// Idempotent — a second call (e.g. `RootView` reappearing) does nothing.
    public func start() {
        guard !hasStarted else { return }
        hasStarted = true

        settings.$autoSend
            // `@Published` emits in `willSet`, before the property itself has
            // changed — hop once so `scheduleSweep` reads the new value rather
            // than the old.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleSweep() }
            .store(in: &cancellables)

        connectivity.connectivityChanges
            .sink { [weak self] _ in self?.scheduleSweep() }
            .store(in: &cancellables)

        submissionStore.$submissions
            .sink { [weak self] _ in self?.scheduleSweep() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.scheduleSweep() }
            .store(in: &cancellables)
    }

    /// The "send when" rule: does the *current* connection satisfy the
    /// *currently selected* `AutoSendMode`? Re-evaluated on every trigger and
    /// again inside the sweep loop, so a mid-sweep change (mode switched off,
    /// or the device moved from Wi-Fi to cellular while "Wi-Fi only" is
    /// selected) stops further sends immediately.
    private var isCurrentConnectivityEligible: Bool {
        settings.autoSend.isEligible(
            isOnline: connectivity.isOnline,
            isOnWiFi: connectivity.isOnWiFi,
            isOnCellular: connectivity.isOnCellular
        )
    }

    private func scheduleSweep() {
        guard settings.autoSend != .off else { return }
        // A sweep is already queued or running: remember to check again once it
        // finishes (handles connectivity flapping and submissions saved mid-sweep)
        // rather than starting an overlapping one.
        if isSweepScheduled || isSweeping {
            sweepAgain = true
            return
        }
        isSweepScheduled = true
        Task { await self.sweep() }
    }

    private func sweep() async {
        isSweepScheduled = false
        guard isCurrentConnectivityEligible, !isSweeping else { return }
        // No project configured ⇒ nothing to authenticate with; nothing to do.
        guard let project = projectProvider() else { return }
        let password = passwordProvider()

        isSweeping = true
        defer { isSweeping = false }

        repeat {
            // Triggers that arrived before this sweep even started are already
            // reflected in the list below — clear them so they don't buy a second
            // pass. Only changes that land *during* a pass (below) set this again.
            sweepAgain = false
            for submission in submissionStore.readyToSendSubmissions {
                // Stop early if the mode/connection stopped being eligible
                // mid-sweep — the in-flight upload is allowed to finish, but
                // nothing new starts.
                guard isCurrentConnectivityEligible else { return }
                do {
                    try await send(submission, project, password)
                } catch {
                    // Silent, non-blocking: the submission stays `.readyToSend` for
                    // the next trigger. Logged so a real failure is still
                    // inspectable rather than swallowed.
                    NSLog("Automatic send failed for \(submission.id): \(error.localizedDescription)")
                }
            }
        } while sweepAgain
    }
}
