import Foundation

public enum OpenRosaError: Error, LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case parsing(Error)
    case network(Error)
    case authenticationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The server returned an unexpected response."
        case .httpStatus(let code):
            return "The server returned HTTP status \(code)."
        case .parsing:
            return "Couldn't parse the server's response."
        case .network(let error):
            return error.localizedDescription
        case .authenticationFailed:
            return "The server rejected the username or password."
        }
    }
}

/// Stateless client for the two OpenRosa endpoints ODK Collect-style apps use to
/// discover and download forms. Holds no app state — construct one per request
/// (or per project) with the server URL and credentials to use.
public struct OpenRosaClient {
    private let serverURL: URL
    private let session: URLSession

    public init(serverURL: URL, username: String, password: String) {
        self.serverURL = serverURL
        let authDelegate = BasicDigestAuthDelegate(username: username, password: password)
        self.session = URLSession(configuration: .default, delegate: authDelegate, delegateQueue: nil)
    }

    /// `GET {serverURL}/formList` — the OpenRosa `xformsList` discovery call.
    public func fetchFormList() async throws -> [RemoteForm] {
        let url = serverURL.appendingPathComponent("formList")
        let data = try await get(url)
        do {
            return try FormListXMLParser.parse(data)
        } catch {
            throw OpenRosaError.parsing(error)
        }
    }

    /// `GET` a form's `downloadUrl` (as provided by a `formList` entry) — the raw XForm XML.
    public func fetchFormXML(from downloadURL: URL) async throws -> Data {
        try await get(downloadURL)
    }

    /// `HEAD {serverURL}/submission` — the OpenRosa-recommended way to check that this
    /// client's credentials are accepted *before* attempting an upload. The server
    /// never runs submission-processing logic for a HEAD request.
    public func probeSubmission() async throws {
        let url = serverURL.appendingPathComponent("submission")
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("1.0", forHTTPHeaderField: "X-OpenRosa-Version")

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw Self.mapTransportError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw OpenRosaError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw OpenRosaError.httpStatus(http.statusCode) }
    }

    /// `POST {serverURL}/submission` — uploads a completed instance, and any media
    /// attachments it references, as an OpenRosa `multipart/form-data` submission.
    public func submit(xml: Data, attachments: [SubmissionAttachment] = []) async throws {
        let url = serverURL.appendingPathComponent("submission")
        let boundary = "Boundary-\(UUID().uuidString)"
        let body = Self.multipartBody(xml: xml, attachments: attachments, boundary: boundary)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("1.0", forHTTPHeaderField: "X-OpenRosa-Version")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw Self.mapTransportError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw OpenRosaError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw OpenRosaError.httpStatus(http.statusCode) }
    }

    /// `session.data(for:)` surfaces a rejected-credential retry loop's abort as a
    /// generic `NSURLErrorUserCancelledAuthentication`, which reads as gibberish to a
    /// user — map it to a clear, specific error instead.
    private static func mapTransportError(_ error: Error) -> OpenRosaError {
        if (error as NSError).code == NSURLErrorUserCancelledAuthentication {
            return .authenticationFailed
        }
        return .network(error)
    }

    /// Builds the exact `multipart/form-data` body `submit` sends: an
    /// `xml_submission_file` part followed by one part per attachment, each named for
    /// its own filename (as OpenRosa expects, so the server can match `<upload>`
    /// values in the instance XML to the files that accompany it). Exposed
    /// independently of `submit` so the wire format can be verified without a network
    /// round-trip.
    public static func multipartBody(xml: Data, attachments: [SubmissionAttachment], boundary: String) -> Data {
        var body = Data()
        appendMultipartField(
            to: &body,
            boundary: boundary,
            name: "xml_submission_file",
            filename: "submission.xml",
            contentType: "text/xml",
            data: xml
        )
        for attachment in attachments {
            appendMultipartField(
                to: &body,
                boundary: boundary,
                name: attachment.filename,
                filename: attachment.filename,
                contentType: attachment.contentType,
                data: attachment.data
            )
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    private static func appendMultipartField(
        to body: inout Data,
        boundary: String,
        name: String,
        filename: String,
        contentType: String,
        data: Data
    ) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!
        )
        body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("1.0", forHTTPHeaderField: "X-OpenRosa-Version")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OpenRosaError.network(error)
        }

        guard let http = response as? HTTPURLResponse else { throw OpenRosaError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw OpenRosaError.httpStatus(http.statusCode) }
        return data
    }
}

/// Answers HTTP Basic/Digest auth challenges with the supplied credential;
/// everything else (e.g. TLS server trust) falls back to default handling.
private final class BasicDigestAuthDelegate: NSObject, URLSessionTaskDelegate {
    private let credential: URLCredential

    init(username: String, password: String) {
        credential = URLCredential(user: username, password: password, persistence: .forSession)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest:
            // The same credential was already offered and rejected once — offering it
            // again would just get re-challenged forever instead of ever failing, since
            // nothing else tells the session to give up.
            guard challenge.previousFailureCount == 0 else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, credential)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
