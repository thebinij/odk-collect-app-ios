import Combine
import Foundation

/// Whether — and over what kind of connection — a `.readyToSend` submission is
/// uploaded on its own, with no tap. A lightweight, `UserDefaults`-backed
/// preference exactly like `ProjectStore` (nothing secret, so no Keychain). A
/// single global setting, not per-project: only one project is configured at a
/// time today.
public enum AutoSendMode: String, Codable, CaseIterable, Identifiable {
    /// The form waits in **Ready to Send** until the user taps **Send Now** —
    /// nothing here ever submits on its own. The default.
    case off
    /// Sends automatically, but only while connected over Wi-Fi.
    case wifiOnly
    /// Sends automatically, but only while connected over cellular (and *not*
    /// simultaneously on Wi-Fi — see `ConnectivityMonitoring` doc comment).
    case cellularOnly
    /// Sends automatically over any connection — Wi-Fi, cellular, or anything
    /// else `NWPathMonitor` reports as online (e.g. wired Ethernet).
    case wifiOrCellular

    public var id: String { rawValue }

    /// The one "send when" rule — does this mode allow sending given the current
    /// connection shape? Shared by `AutoSendCoordinator` (a long-lived, reactive
    /// check while the app is running) and a background task runner (a single
    /// point-in-time check), so the two can't drift apart.
    public func isEligible(isOnline: Bool, isOnWiFi: Bool, isOnCellular: Bool) -> Bool {
        switch self {
        case .off:
            return false
        case .wifiOnly:
            return isOnWiFi
        case .cellularOnly:
            return isOnCellular && !isOnWiFi
        case .wifiOrCellular:
            return isOnline
        }
    }
}

/// Selection persists immediately (no separate "Save" step); `.off` is the
/// default, so shipping this feature changes no existing install's behavior
/// until a user deliberately opts in.
public final class FormSubmissionSettingsStore: ObservableObject {
    private enum Keys {
        static let autoSend = "com.odkcollect.formSubmission.autoSend"
        /// Read once, as a fallback, to carry forward a value saved by the
        /// prior manual/automatic build — see `migratedMode(from:)` below.
        static let legacyMode = "com.odkcollect.sendSettings.mode"
    }

    private let defaults: UserDefaults

    @Published public var autoSend: AutoSendMode {
        didSet { defaults.set(autoSend.rawValue, forKey: Keys.autoSend) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.string(forKey: Keys.autoSend), let mode = AutoSendMode(rawValue: stored) {
            autoSend = mode
        } else {
            autoSend = Self.migratedMode(from: defaults)
        }
    }

    /// One-time migration from the prior build's manual/automatic setting, so
    /// someone who already opted into Automatic Send doesn't silently revert to
    /// Off. `"manual"` → `.off` (equivalent). `"automatic"` → `.wifiOrCellular`
    /// (closest equivalent: the old mode didn't distinguish connection type, so
    /// map it to the new option that likewise sends over any connection).
    /// Anything else (unset, or a value from a build older than that) → `.off`,
    /// same as the store's own default.
    private static func migratedMode(from defaults: UserDefaults) -> AutoSendMode {
        switch defaults.string(forKey: Keys.legacyMode) {
        case "manual": return .off
        case "automatic": return .wifiOrCellular
        default: return .off
        }
    }
}
