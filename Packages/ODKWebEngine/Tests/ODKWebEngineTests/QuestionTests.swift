import XCTest
@testable import ODKWebEngine

final class QuestionTests: XCTestCase {
    private func decode(_ json: String) throws -> Question {
        try JSONDecoder().decode(Question.self, from: Data(json.utf8))
    }

    func testDecodesBasicStringQuestion() throws {
        let question = try decode("""
        {
            "ref": "/data/name", "index": 0, "uid": "/data/name[0]", "typeXml": "string",
            "kind": "string", "label": "Name", "hint": null, "required": true,
            "relevant": true, "readonly": false, "value": "", "options": []
        }
        """)
        XCTAssertEqual(question.ref, "/data/name")
        XCTAssertEqual(question.kind, .string)
        XCTAssertTrue(question.required)
        XCTAssertTrue(question.relevant)
        XCTAssertEqual(question.options, [])
        XCTAssertFalse(question.hidden, "absent 'hidden' should default to false rather than fail to decode")
    }

    /// `appearance="hidden"` fields must be flagged so the native one-question UI can
    /// skip them — they're the standard XLSForm/ODK convention for values that should
    /// never be shown, distinct from a dynamically-false `relevant`.
    func testDecodesHiddenAppearanceFlag() throws {
        let question = try decode("""
        {
            "ref": "/data/secret", "index": 0, "uid": "/data/secret[0]", "typeXml": "string",
            "kind": "string", "label": "Secret", "hint": null, "required": false,
            "relevant": true, "readonly": false, "hidden": true, "value": "", "options": []
        }
        """)
        XCTAssertTrue(question.hidden)
        XCTAssertTrue(question.relevant, "hidden is independent of relevant")
    }

    func testDecodesSelectWithOptions() throws {
        let question = try decode("""
        {
            "ref": "/data/sex", "index": 0, "uid": "/data/sex[0]", "typeXml": "string",
            "kind": "select1", "label": "Sex", "hint": null, "required": false,
            "relevant": true, "readonly": false, "value": "male",
            "options": [{"value": "male", "label": "Male"}, {"value": "female", "label": "Female"}]
        }
        """)
        XCTAssertEqual(question.kind, .select1)
        XCTAssertEqual(question.value, "male")
        XCTAssertEqual(question.options, [
            Question.Option(value: "male", label: "Male"),
            Question.Option(value: "female", label: "Female")
        ])
    }

    /// `rangeMin`/`rangeMax`/`rangeStep` arrive from bridge.js as HTML attribute
    /// strings (e.g. `"0"`), not JSON numbers.
    func testDecodesRangeBoundsFromStrings() throws {
        let question = try decode("""
        {
            "ref": "/data/scale", "index": 0, "uid": "/data/scale[0]", "typeXml": "int",
            "kind": "range", "label": "Scale", "hint": null, "required": false,
            "relevant": true, "readonly": false, "value": "5", "options": [],
            "rangeMin": "0", "rangeMax": "10", "rangeStep": "1"
        }
        """)
        XCTAssertEqual(question.rangeMin, 0)
        XCTAssertEqual(question.rangeMax, 10)
        XCTAssertEqual(question.rangeStep, 1)
    }

    func testUnrecognizedKindFallsBackToUnsupportedRatherThanFailing() throws {
        let question = try decode("""
        {
            "ref": "/data/x", "index": 0, "uid": "/data/x[0]", "typeXml": "someNewType",
            "kind": "someBrandNewWidgetType", "label": "X", "hint": null, "required": false,
            "relevant": true, "readonly": false, "value": "", "options": []
        }
        """)
        XCTAssertEqual(question.kind, .unsupported)
    }

    func testDecodesRepeatFields() throws {
        let question = try decode("""
        {
            "ref": "/data/g/r/item", "index": 1, "uid": "/data/g/r/item[1]", "typeXml": "string",
            "kind": "string", "label": "Item", "hint": null, "required": false,
            "relevant": true, "readonly": false, "value": "", "options": [],
            "repeatRef": "/data/g/r", "repeatIndex": 1, "repeatCount": 2
        }
        """)
        XCTAssertEqual(question.repeatRef, "/data/g/r")
        XCTAssertEqual(question.repeatIndex, 1)
        XCTAssertEqual(question.repeatCount, 2)
    }

    func testDecodesBikramSambatFlag() throws {
        let question = try decode("""
        {
            "ref": "/data/dob", "index": 0, "uid": "/data/dob[0]", "typeXml": "date",
            "kind": "date", "label": "DOB", "hint": null, "required": false,
            "relevant": true, "readonly": false, "bikramSambat": true, "value": "2025-04-14", "options": []
        }
        """)
        XCTAssertTrue(question.bikramSambat)
    }

    func testRepeatSeriesDecoding() throws {
        let data = Data("""
        [{"ref": "/data/g/r", "label": "Group G", "count": 2}]
        """.utf8)
        let series = try JSONDecoder().decode([RepeatSeries].self, from: data)
        XCTAssertEqual(series, [RepeatSeries(ref: "/data/g/r", label: "Group G", count: 2)])
    }
}
