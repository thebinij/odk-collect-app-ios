import Foundation

/// A single `<xform>` entry from an OpenRosa `formList` (xformsList) response.
public struct RemoteForm: Identifiable, Hashable, Sendable, Codable {
    public var id: String { formID }

    public let formID: String
    public let name: String
    public let version: String?
    public let hash: String?
    public let downloadURL: URL
    public let manifestURL: URL?

    public init(
        formID: String,
        name: String,
        version: String?,
        hash: String?,
        downloadURL: URL,
        manifestURL: URL?
    ) {
        self.formID = formID
        self.name = name
        self.version = version
        self.hash = hash
        self.downloadURL = downloadURL
        self.manifestURL = manifestURL
    }
}
