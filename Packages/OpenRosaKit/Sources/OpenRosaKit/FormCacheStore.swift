import Foundation

/// Local, on-disk cache of the form list and each form's own XForm XML — the piece
/// that actually makes "download a form once, fill it out anywhere" possible.
/// Mirrors what ODK Collect (Android) does with its local forms table: sync once
/// while online, then read from local storage from then on, no network required to
/// browse or start a new instance of an already-seen form.
public final class FormCacheStore {
    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = base.appendingPathComponent("FormCache", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// Overwrites the cached form list with the given one — call this after a
    /// successful live `fetchFormList()`, never with a partial/fallback result.
    public func cacheFormList(_ forms: [RemoteForm]) {
        guard let data = try? Self.encoder.encode(forms) else { return }
        try? data.write(to: listURL, options: .atomic)
    }

    /// The last successfully cached form list, or `nil` if nothing has ever been
    /// cached (e.g. this project has never had a successful `formList` fetch).
    public func cachedFormList() -> [RemoteForm]? {
        guard let data = try? Data(contentsOf: listURL) else { return nil }
        return try? Self.decoder.decode([RemoteForm].self, from: data)
    }

    /// Overwrites the cached XForm XML for one form — call this after a successful
    /// live `fetchFormXML(from:)`, keyed by the form's own id (stable across
    /// downloads, unlike its download URL which can include a version/hash). Records
    /// `downloadedAt` (defaulting to now) alongside it, so the Forms list can show
    /// when each form was last actually synced.
    public func cacheFormXML(_ xml: String, formID: String, downloadedAt: Date = Date()) {
        guard let data = try? Self.encoder.encode(CachedForm(xml: xml, downloadedAt: downloadedAt)) else { return }
        try? data.write(to: cacheURL(formID: formID), options: .atomic)
    }

    /// The last successfully cached XML for a form, or `nil` if it's never been
    /// downloaded (or was downloaded before this cache existed).
    public func cachedFormXML(formID: String) -> String? {
        cachedForm(formID: formID)?.xml
    }

    /// When a form's XML was last successfully cached, or `nil` if it's never been
    /// downloaded.
    public func cachedFormDownloadDate(formID: String) -> Date? {
        cachedForm(formID: formID)?.downloadedAt
    }

    private struct CachedForm: Codable {
        let xml: String
        let downloadedAt: Date
    }

    private func cachedForm(formID: String) -> CachedForm? {
        guard let data = try? Data(contentsOf: cacheURL(formID: formID)) else { return nil }
        return try? Self.decoder.decode(CachedForm.self, from: data)
    }

    private var listURL: URL {
        directory.appendingPathComponent("forms.json")
    }

    private func cacheURL(formID: String) -> URL {
        directory.appendingPathComponent("\(Self.sanitizedFilename(for: formID)).json")
    }

    /// A `formID` can contain characters unsafe in a filename (`/`, spaces, ...) —
    /// percent-encode it down to something filesystem-safe while staying stable
    /// (the same formID always maps to the same file) and readable enough to
    /// debug on disk.
    private static func sanitizedFilename(for formID: String) -> String {
        formID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? formID.hashValue.description
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}
