import Combine
import Foundation

/// Live-persists project fields as they're edited (server URL/username via
/// `UserDefaults`, password via Keychain) — there's no separate "save" step; whatever
/// is currently in each field is already what's stored.
public final class ProjectStore: ObservableObject {
    private enum Keys {
        static let serverURLText = "com.odkcollect.project.serverURLText"
        static let username = "com.odkcollect.project.username"
    }

    private let defaults: UserDefaults
    private let keychain: KeychainStore

    @Published public var serverURLText: String {
        didSet { defaults.set(serverURLText, forKey: Keys.serverURLText) }
    }
    @Published public var username: String {
        didSet { defaults.set(username, forKey: Keys.username) }
    }
    @Published public var password: String {
        didSet { keychain.savePassword(password) }
    }

    public init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
        serverURLText = defaults.string(forKey: Keys.serverURLText) ?? ""
        username = defaults.string(forKey: Keys.username) ?? ""
        password = keychain.readPassword() ?? ""
    }

    /// A valid `Project`, derived from the current fields; `nil` while the server URL
    /// or username hasn't yet been filled in with something usable.
    /// Resets every field and removes the stored password from the Keychain outright
    /// (unlike deleting the app, which Keychain entries survive by design).
    public func clear() {
        serverURLText = ""
        username = ""
        password = ""
        keychain.deletePassword()
    }

    public var project: Project? {
        let trimmedURL = serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmedURL.isEmpty,
            let url = URL(string: trimmedURL), url.scheme != nil, url.host != nil,
            !trimmedUsername.isEmpty
        else {
            return nil
        }
        return Project(serverURL: url, username: trimmedUsername)
    }
}
