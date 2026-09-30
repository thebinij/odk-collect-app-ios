import XCTest
@testable import ODKCollectUI

/// Reference values cross-checked against the actual `medic/bikram-sambat` JS
/// library (the same one ODK Collect's Nepali date widget uses) via Node, e.g.:
/// `require('bikram-sambat').toBik('2025-04-14')` → `{ year: 2082, month: 1, day: 1 }`.
final class BikramSambatCalendarTests: XCTestCase {
    func testKnownNepaliNewYearConvertsFromAD() {
        // 2082 Baisakh 1 (Nepali New Year) is a well-known reference date.
        let bs = BikramSambatCalendar.bsDate(fromAD: "2025-04-14")
        XCTAssertEqual(bs, BikramSambatCalendar.BSDate(year: 2082, month: 1, day: 1))
    }

    func testKnownNepaliNewYearConvertsToAD() {
        let ad = BikramSambatCalendar.adDateString(year: 2082, month: 1, day: 1)
        XCTAssertEqual(ad, "2025-04-14")
    }

    func testAnotherKnownReferenceDate() {
        // require('bikram-sambat').toBik('2026-09-30') -> { year: 2083, month: 6, day: 14 }
        let bs = BikramSambatCalendar.bsDate(fromAD: "2026-09-30")
        XCTAssertEqual(bs, BikramSambatCalendar.BSDate(year: 2083, month: 6, day: 14))
    }

    func testRoundTripADToBSToAD() {
        for adString in ["2000-01-01", "1990-06-15", "2020-12-31", "2033-01-01"] {
            guard let bs = BikramSambatCalendar.bsDate(fromAD: adString) else {
                XCTFail("Failed to convert \(adString) to BS")
                continue
            }
            let backToAD = BikramSambatCalendar.adDateString(year: bs.year, month: bs.month, day: bs.day)
            XCTAssertEqual(backToAD, adString, "round-trip mismatch for \(adString)")
        }
    }

    func testDaysInMonthMatchesReference() {
        // require('bikram-sambat').daysInMonth(2082, 1) -> 31
        XCTAssertEqual(BikramSambatCalendar.daysInMonth(year: 2082, month: 1), 31)
    }

    func testOutOfRangeYearReturnsNil() {
        XCTAssertNil(BikramSambatCalendar.adDateString(year: BikramSambatCalendar.maxYear + 1, month: 1, day: 1))
        XCTAssertNil(BikramSambatCalendar.adDateString(year: BikramSambatCalendar.minYear - 1, month: 1, day: 1))
    }

    func testInvalidDayReturnsNil() {
        // Baisakh 2082 has 31 days.
        XCTAssertNil(BikramSambatCalendar.adDateString(year: 2082, month: 1, day: 32))
    }

    func testMonthNamesHasTwelveEntries() {
        XCTAssertEqual(BikramSambatCalendar.monthNames.count, 12)
    }
}
