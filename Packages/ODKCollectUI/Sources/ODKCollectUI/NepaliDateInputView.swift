import SwiftUI

/// A native Bikram Sambat (Nepali calendar) date picker for `date` questions with
/// `appearance="bikram-sambat"` — the ODK/XLSForm convention used across Nepal
/// surveys. The picker itself only ever shows BS year/month/day; `value` (the model
/// binding) is always kept as a plain Gregorian `"yyyy-MM-dd"` string, exactly what a
/// standard `date` field expects — the BS/AD conversion is entirely a display-time
/// concern, invisible to the rest of the form.
struct NepaliDateInputView: View {
    @Binding var value: String

    @State private var year: Int
    @State private var month: Int
    @State private var day: Int

    init(value: Binding<String>) {
        self._value = value
        let today = BikramSambatCalendar.bsDate(fromAD: Self.todayADString()) ?? BikramSambatCalendar.BSDate(year: 2082, month: 1, day: 1)
        let initial = BikramSambatCalendar.bsDate(fromAD: value.wrappedValue) ?? today
        _year = State(initialValue: initial.year)
        _month = State(initialValue: initial.month)
        _day = State(initialValue: initial.day)
    }

    var body: some View {
        HStack(spacing: 0) {
            Picker("Day", selection: $day) {
                // `Text("\($0)")` with an Int goes through `LocalizedStringKey`
                // interpolation, which applies locale-aware number formatting —
                // including thousands separators (e.g. "2,083" for the year).
                // `Text(String($0))` sidesteps that entirely.
                ForEach(1...daysInSelectedMonth, id: \.self) { Text(String($0)).tag($0) }
            }
            .pickerStyle(.wheel)

            Picker("Month", selection: $month) {
                ForEach(1...12, id: \.self) { month in
                    Text(BikramSambatCalendar.monthNames[month - 1]).tag(month)
                }
            }
            .pickerStyle(.wheel)

            Picker("Year", selection: $year) {
                ForEach(BikramSambatCalendar.minYear...BikramSambatCalendar.maxYear, id: \.self) { Text(String($0)).tag($0) }
            }
            .pickerStyle(.wheel)
        }
        .frame(height: 150)
        .onChange(of: day) { _ in commit() }
        .onChange(of: month) { _ in
            day = min(day, daysInSelectedMonth)
            commit()
        }
        .onChange(of: year) { _ in
            day = min(day, daysInSelectedMonth)
            commit()
        }
        .onAppear { commit() }
    }

    private var daysInSelectedMonth: Int {
        BikramSambatCalendar.daysInMonth(year: year, month: month)
    }

    private func commit() {
        if let ad = BikramSambatCalendar.adDateString(year: year, month: month, day: day) {
            value = ad
        }
    }

    private static func todayADString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
