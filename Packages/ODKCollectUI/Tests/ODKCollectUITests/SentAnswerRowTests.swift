import XCTest
import ODKWebEngine
@testable import ODKCollectUI

private func makeQuestion(
    kind: Question.Kind,
    value: String,
    bikramSambat: Bool = false,
    options: [Question.Option] = []
) -> Question {
    Question(
        ref: "/data/q",
        index: 0,
        uid: "/data/q[0]",
        typeXml: "string",
        kind: kind,
        label: "Q",
        hint: nil,
        required: false,
        relevant: true,
        readonly: false,
        hidden: false,
        bikramSambat: bikramSambat,
        value: value,
        options: options,
        rangeMin: nil,
        rangeMax: nil,
        rangeStep: nil,
        repeatRef: nil,
        repeatIndex: nil,
        repeatCount: nil
    )
}

/// Regression: the read-only "Sent Forms" summary showed a Bikram Sambat question's
/// answer as its raw stored Gregorian string (e.g. "2025-04-14") instead of the BS
/// date it was actually answered in — unlike the one-question flow's own
/// `NepaliDateInputView`, which has always displayed it correctly. Reported as
/// "opening english date in nepali date... even in viewing sent forms readonly view."
final class SentAnswerRowTests: XCTestCase {
    func testBikramSambatDateDisplaysAsBSNotTheStoredGregorianString() {
        let question = makeQuestion(kind: .date, value: "2025-04-14", bikramSambat: true)
        XCTAssertEqual(SentAnswerRow.displayValue(for: question), "1 Baisakh 2082")
    }

    func testOrdinaryDateDisplaysAsStoredWithoutBikramSambatConversion() {
        let question = makeQuestion(kind: .date, value: "2025-04-14", bikramSambat: false)
        XCTAssertEqual(SentAnswerRow.displayValue(for: question), "2025-04-14")
    }

    func testUnansweredBikramSambatDateShowsThePlaceholderNotAnEmptyOrCrashingConversion() {
        let question = makeQuestion(kind: .date, value: "", bikramSambat: true)
        XCTAssertEqual(SentAnswerRow.displayValue(for: question), SentAnswerRow.placeholder)
    }

    /// A malformed/out-of-range stored value must fail gracefully to the raw string
    /// rather than crash or silently show nothing.
    func testUnparsableBikramSambatDateFallsBackToTheRawStoredValue() {
        let question = makeQuestion(kind: .date, value: "not-a-date", bikramSambat: true)
        XCTAssertEqual(SentAnswerRow.displayValue(for: question), "not-a-date")
    }

    func testSelect1DisplaysTheOptionsLabelNotItsRawValue() {
        let question = makeQuestion(
            kind: .select1,
            value: "mine",
            options: [Question.Option(value: "mine", label: "My own"), Question.Option(value: "someone_else", label: "Someone else's")]
        )
        XCTAssertEqual(SentAnswerRow.displayValue(for: question), "My own")
    }
}
