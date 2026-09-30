import Foundation

/// The shared "try the live server, fall back to what's cached, only actually fail if
/// neither works" policy this app uses everywhere it needs network data that should
/// still be usable offline (the form list, a form's XML). Generic and side-effect-free
/// on purpose — callers decide what to do with `source` (e.g. write a fresh `.live`
/// result through to a cache, or show an "offline" indicator for a `.cached` one).
public enum OfflineFallback {
    public enum Source: Equatable {
        case live
        case cached
    }

    /// Runs `primary`; if it throws, tries `cached()` and returns that instead if it
    /// has something to offer. Only propagates `primary`'s error when there's truly
    /// nothing cached to fall back to.
    public static func resolve<T>(
        primary: () async throws -> T,
        cached: () -> T?
    ) async throws -> (value: T, source: Source) {
        do {
            return (try await primary(), .live)
        } catch {
            if let cachedValue = cached() {
                return (cachedValue, .cached)
            }
            throw error
        }
    }
}
