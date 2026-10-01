import ODKWebEngine
import SwiftUI

/// Renders one `Question` with the native SwiftUI control matching its `Kind`, as a
/// `Section` meant to sit directly inside the hosting `Form` — this is the entire
/// "visible form"; the Enketo engine's own rendered HTML is never shown. Using a real
/// `Form`/`Section` (rather than custom bordered boxes) gives every text field, list
/// row, and picker the same look and feel as any other native iOS input.
struct QuestionInputView: View {
    let question: Question
    @Binding var value: String
    let onCapturedAttachment: (String, Data) -> Void
    /// Set only when *this* question is the one that just failed validation —
    /// tints its own row red and shows the message directly below it, rather
    /// than as a generic banner elsewhere on the page.
    let errorMessage: String?

    init(
        question: Question,
        value: Binding<String>,
        onCapturedAttachment: @escaping (String, Data) -> Void,
        errorMessage: String? = nil
    ) {
        self.question = question
        self._value = value
        self.onCapturedAttachment = onCapturedAttachment
        self.errorMessage = errorMessage
    }

    private var isInvalid: Bool { errorMessage != nil }

    var body: some View {
        Section {
            control
                .listRowBackground(isInvalid ? Color.red.opacity(0.12) : nil)
        } header: {
            VStack(alignment: .leading, spacing: 4) {
                Text(question.label)
                    .font(.headline)
                    .foregroundStyle(isInvalid ? .red : .primary)
                    .textCase(nil)
                if let hint = question.hint, !hint.isEmpty {
                    Text(hint)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                } else if question.required {
                    Text("Required")
                }
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        switch question.kind {
        case .string:
            TextField("Your answer", text: $value, axis: .vertical)
        case .int:
            TextField("0", text: $value)
                .keyboardType(.numbersAndPunctuation)
        case .decimal:
            TextField("0.0", text: $value)
                .keyboardType(.decimalPad)
        case .select1:
            SingleSelectInputView(options: question.options, value: $value)
        case .select:
            MultiSelectInputView(options: question.options, value: $value)
        case .date:
            if question.bikramSambat {
                NepaliDateInputView(value: $value)
            } else {
                DateValueInputView(value: $value, style: .date)
            }
        case .time:
            DateValueInputView(value: $value, style: .time)
        case .dateTime:
            DateValueInputView(value: $value, style: .dateTime)
        case .note:
            if !question.value.isEmpty {
                Text(question.value)
                    .foregroundStyle(.secondary)
            }
        case .trigger:
            Button {
                value = "OK"
            } label: {
                Label(value == "OK" ? "Acknowledged" : "Tap to Acknowledge", systemImage: value == "OK" ? "checkmark.circle.fill" : "circle")
            }
        case .range:
            RangeInputView(question: question, value: $value)
        case .rank:
            RankInputView(options: question.options, value: $value)
        case .geopoint:
            GeopointInputView(value: $value)
        case .geotrace, .geoshape:
            GeoTraceInputView(value: $value)
        case .signature:
            SignatureInputView(question: question, value: $value, onCapturedAttachment: onCapturedAttachment)
        case .binaryImage:
            ImageAttachmentInputView(question: question, value: $value, onCapturedAttachment: onCapturedAttachment)
        case .binaryAudio:
            AudioAttachmentInputView(question: question, value: $value, onCapturedAttachment: onCapturedAttachment)
        case .binaryVideo, .binaryFile:
            FileAttachmentInputView(question: question, value: $value, onCapturedAttachment: onCapturedAttachment)
        case .unsupported:
            TextField("Your answer", text: $value)
        }
    }
}

/// A native, Settings-style single-choice list: one row per option, a checkmark on
/// the selected one.
struct SingleSelectInputView: View {
    let options: [Question.Option]
    @Binding var value: String

    var body: some View {
        ForEach(options, id: \.value) { option in
            Button {
                value = option.value
            } label: {
                HStack {
                    Text(option.label)
                        .foregroundStyle(.primary)
                    Spacer()
                    if value == option.value {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }
}

/// A native, Settings-style multi-choice list: one row per option, a checkmark on
/// each selected one.
struct MultiSelectInputView: View {
    let options: [Question.Option]
    @Binding var value: String

    private var selected: Set<String> {
        Set(value.split(separator: " ").map(String.init))
    }

    var body: some View {
        ForEach(options, id: \.value) { option in
            Button {
                toggle(option.value)
            } label: {
                HStack {
                    Text(option.label)
                        .foregroundStyle(.primary)
                    Spacer()
                    if selected.contains(option.value) {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }

    private func toggle(_ optionValue: String) {
        var current = selected
        if current.contains(optionValue) {
            current.remove(optionValue)
        } else {
            current.insert(optionValue)
        }
        value = options.map(\.value).filter(current.contains).joined(separator: " ")
    }
}

struct RangeInputView: View {
    let question: Question
    @Binding var value: String

    private var bounds: ClosedRange<Double> {
        let min = question.rangeMin ?? 0
        let max = question.rangeMax ?? 10
        return min <= max ? min...max : max...min
    }

    private var step: Double { question.rangeStep ?? 1 }

    var body: some View {
        VStack(alignment: .leading) {
            Text(displayValue)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)
            Slider(
                value: Binding(
                    get: { Double(value) ?? bounds.lowerBound },
                    set: { value = Self.format($0) }
                ),
                in: bounds,
                step: step > 0 ? step : 1
            )
        }
        .onAppear {
            if value.isEmpty { value = Self.format(bounds.lowerBound) }
        }
    }

    private var displayValue: String {
        value.isEmpty ? "\u{2014}" : value
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }
}
