import Foundation

/// Converts between Gregorian (AD) and Bikram Sambat (BS, Nepal's official calendar)
/// dates — a faithful Swift port of the algorithm and reference data from the
/// Apache-2.0-licensed `medic/bikram-sambat` JS library, the same one ODK Collect's
/// own Nepali date widget (`appearance="bikram-sambat"`) is built on.
///
/// BS is not a simple offset from AD — month lengths vary per year with no closed-form
/// formula — so, like the reference library, this works from a fixed table of encoded
/// month lengths (2 bits per month; each month is 29 + that value days) covering BS
/// years 1970–2090 (~AD 1913–2034).
enum BikramSambatCalendar {
    struct BSDate: Equatable {
        let year: Int
        let month: Int // 1...12
        let day: Int
    }

    static let monthNames = [
        "Baisakh", "Jestha", "Ashadh", "Shrawan", "Bhadra", "Ashwin",
        "Kartik", "Mangsir", "Poush", "Magh", "Falgun", "Chaitra"
    ]

    static let minYear = 1970
    static let maxYear = minYear + encodedMonthLengths.count - 1

    /// The number of days in a given BS month (1...12) of a given BS year.
    static func daysInMonth(year: Int, month: Int) -> Int {
        guard month >= 1, month <= 12, let delta = encodedMonthLengths[safe: year - minYear] else {
            return 30
        }
        return 29 + ((delta >> ((month - 1) << 1)) & 3)
    }

    /// Converts a Gregorian date (as `"yyyy-MM-dd"`) to its BS equivalent, or `nil` if
    /// the string doesn't parse or falls outside the supported range.
    static func bsDate(fromAD adDateString: String) -> BSDate? {
        guard let adDate = adFormatter.date(from: adDateString) else { return nil }
        var days = Int(((adDate.timeIntervalSince1970 * 1000 - epochTimestampMS) / msPerDay).rounded(.down)) + 1
        guard days > 0 else { return nil }

        var year = minYear
        while days > 0, year <= maxYear {
            for month in 1...12 {
                let daysInThisMonth = daysInMonth(year: year, month: month)
                if days <= daysInThisMonth {
                    return BSDate(year: year, month: month, day: days)
                }
                days -= daysInThisMonth
            }
            year += 1
        }
        return nil
    }

    /// Converts a BS date to its Gregorian equivalent, formatted as `"yyyy-MM-dd"`, or
    /// `nil` for an out-of-range or invalid (e.g. day 32) BS date.
    static func adDateString(year: Int, month: Int, day: Int) -> String? {
        guard month >= 1, month <= 12 else { return nil }
        guard year >= minYear, year <= maxYear else { return nil }
        guard day >= 1, day <= daysInMonth(year: year, month: month) else { return nil }

        var timestampMS = epochTimestampMS + msPerDay * Double(day)
        var m = month - 1
        var y = year
        while y >= minYear {
            while m > 0 {
                timestampMS += msPerDay * Double(daysInMonth(year: y, month: m))
                m -= 1
            }
            m = 12
            y -= 1
        }

        let date = Date(timeIntervalSince1970: timestampMS / 1000)
        return adFormatter.string(from: date)
    }

    private static let msPerDay: Double = 86_400_000
    /// 1970-01-01 BS == 1913-04-13 AD — the reference library's chosen epoch.
    private static let epochTimestampMS: Double = -1_789_990_200_000

    private static let adFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // 2 bits per month (12 months → 24 bits) encoding each month's day count as an
    // offset from 29 (0...3, i.e. 29...32 days — 32 never actually occurs but the
    // encoding allows it). One entry per BS year, starting at `minYear`. Sourced
    // directly from `medic/bikram-sambat`'s `ENCODED_MONTH_LENGTHS` table — to
    // extend the range, regenerate from that project's own encoder script.
    private static let encodedMonthLengths: [Int] = [
        5315258, 5314490, 9459438, 8673005, 5315258, 5315066, 9459438, 8673005, 5315258, 5314298,
        9459438, 5327594, 5315258, 5314298, 9459438, 5327594, 5315258, 5314286, 9459438, 5315306,
        5315258, 5314286, 8673006, 5315306, 5315258, 5265134, 8673006, 5315258, 5315258, 9459438,
        8673005, 5315258, 5314298, 9459438, 8673005, 5315258, 5314298, 9459438, 8473322, 5315258,
        5314298, 9459438, 5327594, 5315258, 5314298, 9459438, 5327594, 5315258, 5314286, 8673006,
        5315306, 5315258, 5265134, 8673006, 5315306, 5315258, 9459438, 8673005, 5315258, 5314490,
        9459438, 8673005, 5315258, 5314298, 9459438, 8473325, 5315258, 5314298, 9459438, 5327594,
        5315258, 5314298, 9459438, 5327594, 5315258, 5314286, 9459438, 5315306, 5315258, 5265134,
        8673006, 5315306, 5315258, 5265134, 8673006, 5315258, 5314490, 9459438, 8673005, 5315258,
        5314298, 9459438, 8669933, 5315258, 5314298, 9459438, 8473322, 5315258, 5314298, 9459438,
        5327594, 5315258, 5314286, 9459438, 5315306, 5315258, 5265134, 8673006, 5315306, 5315258,
        5265134, 8673006, 5315258, 5315258, 5527226, 5528046, 5527277, 5528250, 5528057, 5527277,
        5527277
    ]
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
