import Foundation

/// A single ODK-style project: the server this app talks to for OpenRosa discovery
/// and submission.
public struct Project: Equatable, Sendable {
    public let serverURL: URL
    public let username: String

    public init(serverURL: URL, username: String) {
        self.serverURL = serverURL
        self.username = username
    }
}
