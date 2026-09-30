import Foundation

/// A single media file to upload alongside a submission's `xml_submission_file` part,
/// e.g. a photo referenced by an XForm `<upload>` binding.
public struct SubmissionAttachment: Sendable {
    public let filename: String
    public let contentType: String
    public let data: Data

    public init(filename: String, contentType: String, data: Data) {
        self.filename = filename
        self.contentType = contentType
        self.data = data
    }

    /// A reasonable `Content-Type` guess from a filename's extension — shared by
    /// every call site that builds attachments from a `SubmissionStore` entry, so a
    /// fresh submit and a later resend from Ready to Send agree on the same values.
    public static func contentType(forFilename filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "m4a": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "mp4", "mov": return "video/mp4"
        default: return "application/octet-stream"
        }
    }
}
