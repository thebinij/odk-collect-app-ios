import ODKWebEngine
import OpenRosaKit
import ProjectSettingsKit
import SwiftUI

/// Hosts a downloaded (or previously-saved-draft) XForm in the bundled Enketo engine.
///
/// - "Save" serializes whatever has been filled in so far — valid or not — to the
///   local `SubmissionStore` as a `.pending` draft, so progress can be checked out at
///   any point and resumed later, fully offline (the XForm definition is saved
///   alongside the answers).
/// - "Submit" validates, then always saves the completed form locally first — so
///   nothing is lost without a connection — before immediately attempting the OpenRosa
///   upload (HEAD `/submission` to confirm credentials, then POST the instance XML) if
///   a network is available, exactly as Enketo/ODK Collect do.
///
/// Both actions update the same `SubmissionStore` entry in place once one exists for
/// this session (starting from `existingSubmissionID` when resuming a draft), so
/// repeated saves — or a final submit — never create duplicate drafts.
public struct EnketoFormContainerView: View {
    private let formID: String
    private let formName: String
    private let xformXML: String
    private let instanceXML: String?
    private let existingSubmissionID: String?
    private let project: Project
    private let password: String
    private let submissionStore: SubmissionStore
    private let onChangeForm: () -> Void

    @StateObject private var formState = EnketoFormState()
    @State private var reloadToken = UUID()
    @State private var isSubmitting = false
    @State private var isSavingDraft = false
    @State private var submissionAlert: SubmissionAlert?
    @State private var currentSubmissionID: String?
    @State private var isShowingBackConfirmation = false
    /// Set right before a draft save triggered from the "Back" confirmation (as
    /// opposed to a mid-form checkpoint save), so once it completes we know to also
    /// leave the form rather than just dismissing the "Draft Saved" alert in place.
    @State private var isSavingBeforeExit = false
    /// Media captured while answering binary questions (photo/audio/video/file/
    /// signature), keyed by the filename stored as that question's model value.
    @State private var attachments: [String: Data] = [:]

    public init(
        formID: String,
        formName: String,
        xformXML: String,
        instanceXML: String? = nil,
        existingSubmissionID: String? = nil,
        project: Project,
        password: String,
        submissionStore: SubmissionStore,
        onChangeForm: @escaping () -> Void
    ) {
        self.formID = formID
        self.formName = formName
        self.xformXML = xformXML
        self.instanceXML = instanceXML
        self.existingSubmissionID = existingSubmissionID
        self.project = project
        self.password = password
        self.submissionStore = submissionStore
        self.onChangeForm = onChangeForm
        _currentSubmissionID = State(initialValue: existingSubmissionID)

        // Resuming a draft: bring its previously-captured media back in, so
        // re-submitting without touching those questions still includes them.
        if let existingSubmissionID {
            var restored: [String: Data] = [:]
            for filename in submissionStore.attachmentFilenames(for: existingSubmissionID) {
                if let data = try? submissionStore.attachmentData(for: existingSubmissionID, filename: filename) {
                    restored[filename] = data
                }
            }
            _attachments = State(initialValue: restored)
        }
    }

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                // The engine itself is never shown — it exists purely to run XPath
                // relevant/calculate/constraint logic and serialize the final instance
                // XML. Every visible control comes from `QuestionFlowView` instead.
                EnketoFormView(xformXML: xformXML, instanceXML: instanceXML, state: formState)
                    .id(reloadToken)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)

                if formState.isFormReady {
                    QuestionFlowView(formState: formState, attachments: $attachments)
                }

                if formState.isLoading {
                    ProgressView("Loading form\u{2026}")
                        .padding()
                        .background(.background.opacity(0.95))
                }

                if let error = formState.loadError {
                    ErrorRetryView(message: error) {
                        formState.prepareForReload()
                        reloadToken = UUID()
                    }
                }

                if isSubmitting || isSavingDraft {
                    ProgressView(isSubmitting ? "Submitting\u{2026}" : "Saving\u{2026}")
                        .padding()
                        .background(.background.opacity(0.95))
                }
            }
            .navigationTitle(formName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        isShowingBackConfirmation = true
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("Back")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        formState.requestDraftSave()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel("Save")
                    .disabled(!formState.isFormReady || isSubmitting || isSavingDraft)
                }
            }
            .onChange(of: formState.validationFailed) { failed in
                if failed { submissionAlert = .validationFailed }
            }
            .onChange(of: formState.bridgeError) { error in
                if let error { submissionAlert = .failure(error) }
            }
            .onChange(of: formState.submissionXML) { xml in
                guard let xml else { return }
                Task { await submit(xmlString: xml) }
            }
            .onChange(of: formState.draftXML) { xml in
                guard let xml else { return }
                saveDraft(xmlString: xml)
            }
            .confirmationDialog(
                "Save your progress before leaving?",
                isPresented: $isShowingBackConfirmation,
                titleVisibility: .visible
            ) {
                Button("Save Draft") {
                    isSavingBeforeExit = true
                    formState.requestDraftSave()
                }
                Button("Discard", role: .destructive) {
                    onChangeForm()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Save Draft keeps your answers so you can finish later from Drafts. Discard throws away everything entered on this form.")
            }
            .alert(item: $submissionAlert) { alert in
                switch alert {
                case .validationFailed:
                    return Alert(
                        title: Text("Can't Submit"),
                        message: Text("The form contains errors. Please review the highlighted questions."),
                        dismissButton: .default(Text("OK"))
                    )
                case .sent:
                    return Alert(
                        title: Text("Sent"),
                        message: Text("The form was saved and sent successfully."),
                        dismissButton: .default(Text("OK")) { onChangeForm() }
                    )
                case .savedOffline:
                    return Alert(
                        title: Text("Saved"),
                        message: Text("No connection right now, so the form was saved and will show up in Sent once it goes through."),
                        dismissButton: .default(Text("OK")) { onChangeForm() }
                    )
                case .draftSaved:
                    return Alert(
                        title: Text("Draft Saved"),
                        message: Text("Your progress was saved. You'll find it under Drafts to pick back up later."),
                        dismissButton: .default(Text("OK")) {
                            if isSavingBeforeExit {
                                isSavingBeforeExit = false
                                onChangeForm()
                            }
                        }
                    )
                case .failure(let message):
                    return Alert(
                        title: Text("Couldn't Save Form"),
                        message: Text(message),
                        dismissButton: .default(Text("OK"))
                    )
                }
            }
        }
    }

    /// Always saves the completed form locally first, then tries to upload it right
    /// away. If the upload fails (most commonly: no network), the saved copy simply
    /// stays `.pending` for a later retry — it is never lost.
    private func submit(xmlString: String) async {
        isSubmitting = true
        defer { isSubmitting = false }

        let saved: SubmissionStore.Submission
        do {
            saved = try submissionStore.save(
                xml: xmlString,
                xformXML: xformXML,
                formID: formID,
                formName: formName,
                attachments: attachments,
                existingID: currentSubmissionID
            )
            currentSubmissionID = saved.id
        } catch {
            submissionAlert = .failure(error.localizedDescription)
            return
        }

        let client = OpenRosaClient(serverURL: project.serverURL, username: project.username, password: password)
        do {
            try await client.probeSubmission()
            try await client.submit(xml: Data(xmlString.utf8), attachments: submissionAttachments())
            submissionStore.markSent(saved.id)
            submissionAlert = .sent
        } catch {
            submissionAlert = .savedOffline
        }
    }

    /// Checkpoints the current (possibly incomplete) answers as a `.pending` draft —
    /// no network involved, no validation required.
    private func saveDraft(xmlString: String) {
        isSavingDraft = true
        defer { isSavingDraft = false }

        do {
            let saved = try submissionStore.save(
                xml: xmlString,
                xformXML: xformXML,
                formID: formID,
                formName: formName,
                attachments: attachments,
                existingID: currentSubmissionID
            )
            currentSubmissionID = saved.id
            submissionAlert = .draftSaved
        } catch {
            submissionAlert = .failure(error.localizedDescription)
        }
    }

    private func submissionAttachments() -> [SubmissionAttachment] {
        attachments.map { filename, data in
            SubmissionAttachment(filename: filename, contentType: Self.contentType(forFilename: filename), data: data)
        }
    }

    private static func contentType(forFilename filename: String) -> String {
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

private enum SubmissionAlert: Identifiable {
    case validationFailed
    case sent
    case savedOffline
    case draftSaved
    case failure(String)

    var id: String {
        switch self {
        case .validationFailed: return "validationFailed"
        case .sent: return "sent"
        case .savedOffline: return "savedOffline"
        case .draftSaved: return "draftSaved"
        case .failure(let message): return "failure-\(message)"
        }
    }
}

private struct ErrorRetryView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Button("Retry", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.background.opacity(0.95))
    }
}
