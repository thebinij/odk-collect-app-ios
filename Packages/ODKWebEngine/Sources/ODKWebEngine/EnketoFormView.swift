import SwiftUI
import WebKit

/// The result of validating one question, reported by `EnketoFormState.validateQuestion`.
public struct QuestionValidationResult: Equatable, Sendable {
    public let uid: String
    public let valid: Bool
    public let message: String?
}

/// The result of validating every question on a `field-list` group's page at once,
/// reported by `EnketoFormState.validateQuestions`.
public struct GroupValidationResult: Equatable, Sendable {
    public let results: [QuestionValidationResult]
    public var allValid: Bool { results.allSatisfy(\.valid) }
    public var firstInvalid: QuestionValidationResult? { results.first { !$0.valid } }
}

/// Observable state for a hosted `EnketoFormView`: drives loading an XForm's raw XML
/// (optionally resuming a saved draft's answers) into the bundled engine, and surfaces
/// the engine's async replies back to SwiftUI — both the whole-form ones (ready/error,
/// validation result, serialized submission/draft XML) and the headless per-question
/// model API (`questions`, `setValue`, `validateQuestion`, repeat add/remove) that
/// drives a fully native "one question at a time" UI without ever showing this
/// WebView's own rendered HTML.
public final class EnketoFormState: NSObject, ObservableObject, WKScriptMessageHandler {
    @Published public internal(set) var isLoading = true
    @Published public internal(set) var loadError: String?
    @Published public internal(set) var isFormReady = false
    @Published public internal(set) var validationFailed = false
    @Published public internal(set) var submissionXML: String?
    @Published public internal(set) var draftXML: String?
    @Published public internal(set) var bridgeError: String?

    @Published public internal(set) var questions: [Question] = []
    @Published public internal(set) var repeats: [RepeatSeries] = []
    @Published public internal(set) var lastValidationResult: QuestionValidationResult?
    @Published public internal(set) var lastGroupValidationResult: GroupValidationResult?

    weak var webView: WKWebView?

    public override init() { super.init() }

    /// Resets load state ahead of a forced reload — pair with re-creating the hosting
    /// `EnketoFormView` (e.g. via a changed SwiftUI `.id()`).
    public func prepareForReload() {
        isLoading = true
        loadError = nil
        isFormReady = false
    }

    func loadForm(xml: String, instanceXML: String?) {
        guard let webView, let argsJSON = Self.encodeArgs([xml, instanceXML as Any]) else { return }
        webView.evaluateJavaScript("window.ODKBridge.loadForm.apply(null, \(argsJSON));")
    }

    /// Asks the engine to validate the current answers and, if valid, serialize them
    /// to submission XML. The result (or failure) arrives via `submissionXML`,
    /// `validationFailed`, or `bridgeError`.
    public func requestSubmission() {
        validationFailed = false
        submissionXML = nil
        bridgeError = nil
        webView?.evaluateJavaScript("window.ODKBridge.submit();")
    }

    /// Asks the engine to serialize whatever has been filled in so far — valid or
    /// not — as a checkpoint to resume later. The result arrives via `draftXML`.
    public func requestDraftSave() {
        draftXML = nil
        bridgeError = nil
        webView?.evaluateJavaScript("window.ODKBridge.save();")
    }

    /// Re-fetches the current question list (and each repeat series' state) from the
    /// model — labels/options are static, but `relevant`/`value` reflect live state.
    public func requestQuestions() {
        webView?.evaluateJavaScript("window.ODKBridge.getQuestions();")
    }

    /// Sets one question's value directly in the model (bypassing this WebView's own,
    /// never-shown, rendered inputs entirely), which re-runs enketo-core's normal
    /// relevant/calculate cascade. `questions` refreshes once the engine replies.
    public func setValue(ref: String, index: Int, value: String, typeXml: String) {
        guard let argsJSON = Self.encodeArgs([ref, index, value, typeXml]) else { return }
        webView?.evaluateJavaScript("window.ODKBridge.setValue.apply(null, \(argsJSON));")
    }

    /// Validates one question's `required`/`constraint` against its current value. The
    /// result arrives via `lastValidationResult`.
    public func validateQuestion(ref: String, index: Int) {
        guard let argsJSON = Self.encodeArgs([ref, index]) else { return }
        webView?.evaluateJavaScript("window.ODKBridge.validateQuestion.apply(null, \(argsJSON));")
    }

    /// Validates every question on a `field-list` group's page at once — they're
    /// answered together, so they're checked together. The result arrives via
    /// `lastGroupValidationResult`.
    public func validateQuestions(_ items: [(ref: String, index: Int)]) {
        let encoded = items.map { ["ref": $0.ref, "index": $0.index] as [String: Any] }
        guard let argsJSON = Self.encodeArgs([encoded]) else { return }
        webView?.evaluateJavaScript("window.ODKBridge.validateQuestions.apply(null, \(argsJSON));")
    }

    /// Adds a new instance to a repeat series. `questions`/`repeats` refresh once the
    /// engine replies.
    public func addRepeatInstance(repeatRef: String) {
        guard let argsJSON = Self.encodeArgs([repeatRef]) else { return }
        webView?.evaluateJavaScript("window.ODKBridge.addRepeatInstance.apply(null, \(argsJSON));")
    }

    /// Removes one instance of a repeat series. `questions`/`repeats` refresh once the
    /// engine replies.
    public func removeRepeatInstance(repeatRef: String, index: Int) {
        guard let argsJSON = Self.encodeArgs([repeatRef, index]) else { return }
        webView?.evaluateJavaScript("window.ODKBridge.removeRepeatInstance.apply(null, \(argsJSON));")
    }

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "formReady":
            isFormReady = true
            requestQuestions()
        case "formError":
            loadError = body["message"] as? String ?? "Couldn't load the form."
        case "validationFailed":
            validationFailed = true
        case "submissionReady":
            submissionXML = body["xml"] as? String
        case "draftReady":
            draftXML = body["xml"] as? String
        case "submitError", "saveError":
            bridgeError = body["message"] as? String ?? "Couldn't prepare the form."
        case "questions":
            questions = Self.decodeQuestions(body["questions"])
            repeats = Self.decodeRepeats(body["repeats"])
        case "questionsError":
            bridgeError = body["message"] as? String ?? "Couldn't read the form's questions."
        case "validationResult":
            guard let ref = body["ref"] as? String, let index = body["index"] as? Int else { return }
            lastValidationResult = QuestionValidationResult(
                uid: "\(ref)[\(index)]",
                valid: body["valid"] as? Bool ?? true,
                message: body["message"] as? String
            )
        case "groupValidationResult":
            guard let rawResults = body["results"] as? [[String: Any]] else { return }
            lastGroupValidationResult = GroupValidationResult(
                results: rawResults.compactMap { entry in
                    guard let ref = entry["ref"] as? String, let index = entry["index"] as? Int else { return nil }
                    return QuestionValidationResult(
                        uid: "\(ref)[\(index)]",
                        valid: entry["valid"] as? Bool ?? true,
                        message: entry["message"] as? String
                    )
                }
            )
        default:
            break
        }
    }

    private static func encodeArgs(_ args: [Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: args) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeQuestions(_ raw: Any?) -> [Question] {
        guard let raw, let data = try? JSONSerialization.data(withJSONObject: raw) else { return [] }
        return (try? JSONDecoder().decode([Question].self, from: data)) ?? []
    }

    private static func decodeRepeats(_ raw: Any?) -> [RepeatSeries] {
        guard let raw, let data = try? JSONSerialization.data(withJSONObject: raw) else { return [] }
        return (try? JSONDecoder().decode([RepeatSeries].self, from: data)) ?? []
    }
}

/// Hosts the bundled Enketo engine (enketo-transformer + enketo-core, vendored as local
/// web assets) in a JS-enabled `WKWebView` and feeds it a downloaded XForm's raw XML
/// directly — form rendering and validation happen entirely on-device, with no
/// dependency on an externally hosted Enketo webform. Passing `instanceXML` resumes a
/// previously-saved draft's answers instead of starting from a blank form.
public struct EnketoFormView: UIViewRepresentable {
    private let xformXML: String
    private let instanceXML: String?
    @ObservedObject private var state: EnketoFormState

    public init(xformXML: String, instanceXML: String? = nil, state: EnketoFormState) {
        self.xformXML = xformXML
        self.instanceXML = instanceXML
        self.state = state
    }

    public func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(state, name: "odk")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        state.webView = webView

        if let indexURL = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "EnketoEngine") {
            webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        } else {
            state.isLoading = false
            state.loadError = "The bundled form engine is missing from the app."
        }
        return webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {}

    public func makeCoordinator() -> Coordinator {
        Coordinator(state: state, xformXML: xformXML, instanceXML: instanceXML)
    }

    public static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "odk")
    }

    public final class Coordinator: NSObject, WKNavigationDelegate {
        private let state: EnketoFormState
        private let xformXML: String
        private let instanceXML: String?

        init(state: EnketoFormState, xformXML: String, instanceXML: String?) {
            self.state = state
            self.xformXML = xformXML
            self.instanceXML = instanceXML
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            state.isLoading = false
            state.loadForm(xml: xformXML, instanceXML: instanceXML)
        }

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            state.isLoading = false
            state.loadError = error.localizedDescription
        }

        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            state.isLoading = false
            state.loadError = error.localizedDescription
        }
    }
}
