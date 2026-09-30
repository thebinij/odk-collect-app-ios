import ODKWebEngine
import SwiftUI

/// A native reorderable list for `rank` questions, meant to sit inside the hosting
/// `Form`'s section — the model value is the options' values in the order the user
/// arranges them, space-separated.
struct RankInputView: View {
    let options: [Question.Option]
    @Binding var value: String

    @State private var order: [Question.Option] = []

    var body: some View {
        Text("Drag to rank, top = first")
            .font(.caption)
            .foregroundStyle(.secondary)

        ForEach(order, id: \.value) { option in
            Text(option.label)
        }
        .onMove { indices, newOffset in
            order.move(fromOffsets: indices, toOffset: newOffset)
            commit()
        }
        .environment(\.editMode, .constant(.active))
        .onAppear {
            if order.isEmpty {
                order = Self.initialOrder(options: options, value: value)
                if value.isEmpty { commit() }
            }
        }
    }

    private func commit() {
        value = order.map(\.value).joined(separator: " ")
    }

    private static func initialOrder(options: [Question.Option], value: String) -> [Question.Option] {
        let savedOrder = value.split(separator: " ").map(String.init)
        guard !savedOrder.isEmpty else { return options }
        var byValue = Dictionary(uniqueKeysWithValues: options.map { ($0.value, $0) })
        var result = savedOrder.compactMap { byValue.removeValue(forKey: $0) }
        result.append(contentsOf: options.filter { byValue[$0.value] != nil })
        return result
    }
}
