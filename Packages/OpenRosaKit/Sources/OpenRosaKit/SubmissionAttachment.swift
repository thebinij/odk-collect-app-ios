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
}
