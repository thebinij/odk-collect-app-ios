import SwiftUI

enum DateValueStyle {
    case date, time, dateTime
}

/// A native `DatePicker` bound to a `date`/`time`/`dateTime` question's string value.
/// enketo-core's model normalizes whatever reasonably-formatted string it's given
/// (adding milliseconds/timezone as needed), so this only needs to produce a
/// consistent, parseable format — not replicate the model's own canonical one.
struct DateValueInputView: View {
    @Binding var value: String
    let style: DateValueStyle

    var body: some View {
        DatePicker("", selection: dateBinding, displayedComponents: components)
            .datePickerStyle(.wheel)
            .labelsHidden()
            .frame(maxWidth: .infinity)
    }

    private var components: DatePicker.Components {
        switch style {
        case .date: return [.date]
        case .time: return [.hourAndMinute]
        case .dateTime: return [.date, .hourAndMinute]
        }
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: { Self.parse(value, style: style) ?? Date() },
            set: { value = Self.format($0, style: style) }
        )
    }

    private static func format(_ date: Date, style: DateValueStyle) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        switch style {
        case .date: formatter.dateFormat = "yyyy-MM-dd"
        case .time: formatter.dateFormat = "HH:mm:ss"
        case .dateTime: formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        }
        return formatter.string(from: date)
    }

    private static func parse(_ value: String, style: DateValueStyle) -> Date? {
        guard !value.isEmpty else { return nil }
        let patterns: [String]
        switch style {
        case .date:
            patterns = ["yyyy-MM-dd"]
        case .time:
            patterns = ["HH:mm:ss.SSSZZZZZ", "HH:mm:ssZZZZZ", "HH:mm:ss", "HH:mm"]
        case .dateTime:
            patterns = [
                "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ",
                "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
                "yyyy-MM-dd'T'HH:mm:ss"
            ]
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for pattern in patterns {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }
}
