import ODKWebEngine
import SwiftUI

/// Drives a fully native "one question at a time" UI on top of the headless Enketo
/// engine: the engine (hidden, zero-size) owns XPath relevant/calculate/constraint
/// evaluation and the instance model; every visible control here is plain SwiftUI,
/// with edits written into the model via `EnketoFormState.setValue`.
public struct QuestionFlowView: View {
    @ObservedObject var formState: EnketoFormState
    /// Media captured for binary questions (photo/audio/video/file/signature),
    /// keyed by the filename stored as that question's model value. Merge into the
    /// submission's attachments when saving/submitting.
    @Binding var attachments: [String: Data]

    @State private var navigator = QuestionFlowNavigator()
    @State private var draftValue: String = ""
    @State private var validationMessage: String?
    /// The specific question the current `validationMessage` belongs to — shown
    /// directly below *that* question's own control (and tints it red), rather
    /// than as a generic banner elsewhere on the page.
    @State private var invalidUID: String?
    @State private var isBusy = false

    public init(formState: EnketoFormState, attachments: Binding<[String: Data]>) {
        self.formState = formState
        self._attachments = attachments
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let step = navigator.current {
                // No "Question X of Y" counter: skip logic means the total shifts as
                // answers reveal or hide later questions, so a fixed count would be
                // misleading rather than reassuring.
                Form {
                    stepContent(step)
                }

                navigationBar(step)
            } else {
                ProgressView("Loading questions\u{2026}")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: formState.questions) { _ in refreshSteps() }
        .onChange(of: formState.repeats) { _ in refreshSteps() }
        .onChange(of: navigator.current?.id) { _ in loadDraftValue() }
        .onChange(of: formState.lastValidationResult) { result in
            guard let result, result.uid == currentUID else { return }
            isBusy = false
            if result.valid {
                validationMessage = nil
                invalidUID = nil
                // Always just advance — a valid last question moves on to the
                // `.finish` step (always the true last step), which is where
                // "Send"/"Save Draft" actually live.
                navigator.advance()
            } else {
                validationMessage = result.message ?? "This answer isn't valid."
                invalidUID = result.uid
            }
        }
        .onChange(of: formState.lastGroupValidationResult) { result in
            guard let result, let currentGroupUIDs, Set(result.results.map(\.uid)) == currentGroupUIDs else { return }
            isBusy = false
            if result.allValid {
                validationMessage = nil
                invalidUID = nil
                navigator.advance()
            } else {
                validationMessage = result.firstInvalid?.message ?? "Some answers aren't valid."
                invalidUID = result.firstInvalid?.uid
            }
        }
        .onAppear {
            refreshSteps()
            loadDraftValue()
        }
    }

    private var currentUID: String? {
        guard case .question(let question) = navigator.current else { return nil }
        return question.uid
    }

    private var currentGroupUIDs: Set<String>? {
        guard case .questionGroup(_, _, let questions) = navigator.current else { return nil }
        return Set(questions.map(\.uid))
    }

    @ViewBuilder
    private func stepContent(_ step: QuestionFlowEngine.Step) -> some View {
        switch step {
        case .question(let question):
            QuestionInputView(
                question: question,
                value: $draftValue,
                onCapturedAttachment: { filename, data in attachments[filename] = data },
                errorMessage: question.uid == invalidUID ? validationMessage : nil
            )
        case .questionGroup(_, let label, let questions):
            if let label, !label.isEmpty {
                Section {
                } header: {
                    Text(label)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }
            }
            // Edits write straight into the model (rather than a local draft
            // committed on "Next") so relevant/calculate cascades between fields
            // in the *same* group show up live — this is a real page, not a
            // sequence of one-off questions.
            ForEach(questions) { question in
                QuestionInputView(
                    question: question,
                    value: groupValueBinding(for: question),
                    onCapturedAttachment: { filename, data in attachments[filename] = data },
                    errorMessage: question.uid == invalidUID ? validationMessage : nil
                )
            }
        case .addRepeat(let series):
            AddRepeatPromptView(series: series) {
                formState.addRepeatInstance(repeatRef: series.ref)
            } onSkip: {
                navigator.advance()
            }
        case .finish:
            FinishPromptView(
                onSend: { formState.requestSubmission() },
                onSaveDraft: { formState.requestDraftSave() }
            )
        }
    }

    @ViewBuilder
    private func navigationBar(_ step: QuestionFlowEngine.Step) -> some View {
        HStack {
            Button {
                validationMessage = nil
                invalidUID = nil
                navigator.retreat()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(navigator.isAtStart)

            Spacer()

            switch step {
            case .question(let question):
                Button {
                    commitAndAdvance(question)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
            case .questionGroup(_, _, let questions):
                Button {
                    commitGroupAndAdvance(questions)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
            case .addRepeat, .finish:
                EmptyView()
            }
        }
        .padding()
    }

    private func groupValueBinding(for question: Question) -> Binding<String> {
        Binding(
            get: { question.value },
            set: { formState.setValue(ref: question.ref, index: question.index, value: $0, typeXml: question.typeXml) }
        )
    }

    private func commitAndAdvance(_ question: Question) {
        isBusy = true
        formState.setValue(ref: question.ref, index: question.index, value: draftValue, typeXml: question.typeXml)
        formState.validateQuestion(ref: question.ref, index: question.index)
    }

    private func commitGroupAndAdvance(_ questions: [Question]) {
        isBusy = true
        formState.validateQuestions(questions.map { (ref: $0.ref, index: $0.index) })
    }

    private func refreshSteps() {
        navigator.updateSteps(QuestionFlowEngine.buildSteps(questions: formState.questions, repeats: formState.repeats))
    }

    private func loadDraftValue() {
        validationMessage = nil
        invalidUID = nil
        if case .question(let question) = navigator.current {
            draftValue = question.value
        } else {
            draftValue = ""
        }
    }
}

/// The last step's content — "Send" / "Save Draft" as ordinary rows inside the
/// same scrollable `Form`, matching every other step (`AddRepeatPromptView`
/// included) instead of living in the fixed bottom bar.
private struct FinishPromptView: View {
    let onSend: () -> Void
    let onSaveDraft: () -> Void

    var body: some View {
        Section {
            Button(action: onSend) {
                Label("Send", systemImage: "paperplane.fill")
            }
            Button(action: onSaveDraft) {
                Label("Save Draft", systemImage: "square.and.arrow.down")
            }
        } header: {
            Label("Every question has been answered", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .textCase(nil)
        } footer: {
            Text("Send this form now, or save it as a draft to review or finish later.")
        }
    }
}

private struct AddRepeatPromptView: View {
    let series: RepeatSeries
    let onAdd: () -> Void
    let onSkip: () -> Void

    var body: some View {
        Section {
            Button("Add Another", action: onAdd)
            Button("No, Continue", action: onSkip)
        } header: {
            Text("Add another \(series.label)?")
                .textCase(nil)
        } footer: {
            Text("You've filled in \(series.count) so far.")
        }
    }
}
