import Combine
import Foundation
import Network

/// Enough reachability to answer "are we online right now, over what kind of
/// connection, and did that change?" — used by `AutoSendCoordinator` to decide
/// whether the current connection matches the selected `AutoSendMode`.
///
/// A protocol so `AutoSendCoordinator` can be tested against a fake that flips
/// connectivity on command, rather than driving a real `NWPathMonitor`.
public protocol ConnectivityMonitoring: AnyObject {
    var isOnline: Bool { get }
    /// True while `NWPathMonitor` reports the active path uses a Wi-Fi
    /// interface. Not mutually exclusive with `isOnCellular` in rare dual-path
    /// cases (e.g. Wi-Fi + a simultaneously active cellular path) — callers that
    /// need "cellular but *not* Wi-Fi" (see `AutoSendMode.cellularOnly`) must
    /// check both flags themselves; this type makes no such judgment call.
    var isOnWiFi: Bool { get }
    /// True while `NWPathMonitor` reports the active path uses a cellular
    /// interface.
    var isOnCellular: Bool { get }
    /// Emits whenever `isOnline`, `isOnWiFi`, or `isOnCellular` changes (not
    /// once per raw path-monitor callback — only on an actual change to one of
    /// the three).
    var connectivityChanges: AnyPublisher<Void, Never> { get }
}

/// `NWPathMonitor` wrapper. All three published properties update on the main
/// thread so SwiftUI (and `AutoSendCoordinator`) can react to them directly.
public final class ConnectivityMonitor: ObservableObject, ConnectivityMonitoring {
    @Published public private(set) var isOnline: Bool = false
    @Published public private(set) var isOnWiFi: Bool = false
    @Published public private(set) var isOnCellular: Bool = false

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.odkcollect.connectivity-monitor")
    private var isStarted = false

    private let changesSubject = PassthroughSubject<Void, Never>()
    public var connectivityChanges: AnyPublisher<Void, Never> { changesSubject.eraseToAnyPublisher() }

    public init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
    }

    /// Begins monitoring, once. `NWPathMonitor.start` may only be called a single
    /// time, so repeat calls (e.g. `RootView` appearing again) are ignored.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let wifi = online && path.usesInterfaceType(.wifi)
            let cellular = online && path.usesInterfaceType(.cellular)
            DispatchQueue.main.async {
                guard let self else { return }
                let changed = online != self.isOnline || wifi != self.isOnWiFi || cellular != self.isOnCellular
                self.isOnline = online
                self.isOnWiFi = wifi
                self.isOnCellular = cellular
                if changed { self.changesSubject.send(()) }
            }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}

extension ConnectivityMonitor {
    /// A single up-to-date reading of the current path, independent of `start()`/
    /// the `@Published` properties — for a background task, which needs one answer
    /// for its one bounded run rather than a long-lived, ongoing monitor. Uses its
    /// own throwaway `NWPathMonitor`, since the app's main one may not exist yet
    /// (a `BGAppRefreshTask` can fire in a fresh process with no UI ever created).
    public static func currentSnapshot() async -> (isOnline: Bool, isOnWiFi: Bool, isOnCellular: Bool) {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "com.odkcollect.connectivity-snapshot")
            // `pathUpdateHandler` could in principle fire again before `cancel()`
            // actually takes effect — guard so the continuation is only ever
            // resumed once. `nonisolated(unsafe)` because every invocation runs
            // serially on this same dedicated `queue` (Swift's data-race checker
            // can't see that guarantee from `NWPathMonitor`'s API shape alone).
            nonisolated(unsafe) var didResume = false
            monitor.pathUpdateHandler = { path in
                guard !didResume else { return }
                didResume = true
                let online = path.status == .satisfied
                continuation.resume(returning: (
                    isOnline: online,
                    isOnWiFi: online && path.usesInterfaceType(.wifi),
                    isOnCellular: online && path.usesInterfaceType(.cellular)
                ))
                monitor.cancel()
            }
            monitor.start(queue: queue)
        }
    }
}
