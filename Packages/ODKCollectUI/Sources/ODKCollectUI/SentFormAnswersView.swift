import ODKWebEngine
import OpenRosaKit
import SwiftUI

/// Shows every answer in a sent form on one scrollable, read-only page — no raw XML,
/// no editing (it's already been uploaded).
struct SentFormAnswersView: View {
    let submission: SubmissionStore.Submission
    let submissionStore: SubmissionStore

    @StateObject private var formState = EnketoFormState()
    @State private var xformXML: String?
    @State private var instanceXML: String?
    @State private var loadError: String?

    var body: some View {
        ZStack {
            if let xformXML, let instanceXML {
                // Headless — runs the model just long enough to read back every
                // question's current value; never shown to the user.
                EnketoFormView(xformXML: xformXML, instanceXML: instanceXML, state: formState)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }

            if formState.isFormReady {
                let questions = formState.questions.filter { $0.relevant && !$0.hidden }
                if questions.isEmpty {
                    Text("This form has no questions.")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(questions) { question in
                                SentAnswerRow(question: question)
                            }
                        }
                        .padding()
                    }
                }
            } else if let error = formState.loadError ?? loadError {
                Text(error)
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ProgressView("Loading\u{2026}")
            }
        }
        .navigationTitle(submission.formName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                xformXML = try submissionStore.xformXML(for: submission.id)
                instanceXML = String(decoding: try submissionStore.xmlData(for: submission.id), as: UTF8.self)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}

private struct SentAnswerRow: View {
    let question: Question

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(question.label)
                .font(.subheadline)
                .fontWeight(.semibold)
            if let displayValue {
                Text(displayValue)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayValue: String? {
        switch question.kind {
        case .note:
            return nil
        case .select1:
            return question.options.first(where: { $0.value == question.value })?.label ?? placeholder
        case .select:
            let selected = question.value.split(separator: " ").map(String.init)
            guard !selected.isEmpty else { return placeholder }
            let labels = selected.compactMap { value in question.options.first(where: { $0.value == value })?.label }
            return labels.isEmpty ? placeholder : labels.joined(separator: ", ")
        case .trigger:
            return question.value == "OK" ? "Acknowledged" : "Not acknowledged"
        case .signature, .binaryImage, .binaryAudio, .binaryVideo, .binaryFile:
            return question.value.isEmpty ? placeholder : "Attached: \(question.value)"
        default:
            return question.value.isEmpty ? placeholder : question.value
        }
    }

    private var placeholder: String { "Not answered" }
}
