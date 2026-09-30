import XCTest
import ODKWebEngine
@testable import ODKCollectUI

private func makeQuestion(
    ref: String,
    index: Int = 0,
    kind: Question.Kind = .string,
    relevant: Bool = true,
    hidden: Bool = false,
    repeatRef: String? = nil,
    repeatIndex: Int? = nil,
    repeatCount: Int? = nil,
    fieldListGroupRef: String? = nil,
    fieldListGroupLabel: String? = nil
) -> Question {
    Question(
        ref: ref,
        index: index,
        uid: "\(ref)[\(index)]",
        typeXml: "string",
        kind: kind,
        label: ref,
        hint: nil,
        required: false,
        relevant: relevant,
        readonly: false,
        hidden: hidden,
        value: "",
        options: [],
        rangeMin: nil,
        rangeMax: nil,
        rangeStep: nil,
        repeatRef: repeatRef,
        repeatIndex: repeatIndex,
        repeatCount: repeatCount,
        fieldListGroupRef: fieldListGroupRef,
        fieldListGroupLabel: fieldListGroupLabel
    )
}

final class QuestionFlowEngineTests: XCTestCase {
    func testLinearFormProducesOneStepPerQuestionInOrder() {
        let questions = [
            makeQuestion(ref: "/data/a"),
            makeQuestion(ref: "/data/b"),
            makeQuestion(ref: "/data/c")
        ]
        let steps = QuestionFlowEngine.buildSteps(questions: questions, repeats: [])
        XCTAssertEqual(steps.map(\.id), ["q:/data/a[0]", "q:/data/b[0]", "q:/data/c[0]", "finish"])
    }

    func testIrrelevantQuestionsAreSkippedEntirely() {
        let questions = [
            makeQuestion(ref: "/data/a"),
            makeQuestion(ref: "/data/bonus", relevant: false),
            makeQuestion(ref: "/data/c")
        ]
        let steps = QuestionFlowEngine.buildSteps(questions: questions, repeats: [])
        XCTAssertEqual(steps.map(\.id), ["q:/data/a[0]", "q:/data/c[0]", "finish"])
    }

    func testAddRepeatStepAppearsOnlyAfterTheLastInstancesLastQuestion() {
        let questions = [
            makeQuestion(ref: "/data/name"),
            makeQuestion(ref: "/data/g/r/item", index: 0, repeatRef: "/data/g/r", repeatIndex: 0, repeatCount: 2),
            makeQuestion(ref: "/data/g/r/item", index: 1, repeatRef: "/data/g/r", repeatIndex: 1, repeatCount: 2)
        ]
        let repeats = [RepeatSeries(ref: "/data/g/r", label: "Group G", count: 2)]
        let steps = QuestionFlowEngine.buildSteps(questions: questions, repeats: repeats)

        XCTAssertEqual(steps.map(\.id), [
            "q:/data/name[0]",
            "q:/data/g/r/item[0]",
            "q:/data/g/r/item[1]",
            "r:/data/g/r",
            "finish"
        ])
    }

    func testMultiQuestionRepeatInstanceOnlyGetsOneAddStepAfterItsLastQuestion() {
        let questions = [
            makeQuestion(ref: "/data/g/r/first", index: 0, repeatRef: "/data/g/r", repeatIndex: 0, repeatCount: 1),
            makeQuestion(ref: "/data/g/r/second", index: 0, repeatRef: "/data/g/r", repeatIndex: 0, repeatCount: 1)
        ]
        let repeats = [RepeatSeries(ref: "/data/g/r", label: "Group G", count: 1)]
        let steps = QuestionFlowEngine.buildSteps(questions: questions, repeats: repeats)

        XCTAssertEqual(steps.map(\.id), [
            "q:/data/g/r/first[0]",
            "q:/data/g/r/second[0]",
            "r:/data/g/r",
            "finish"
        ])
    }

    /// `appearance="hidden"` fields (the XLSForm/ODK convention for a value that must
    /// never be shown, e.g. a calculated/externally-set field that still needs a body
    /// binding) report `relevant: true` from the engine — only `hidden` marks them as
    /// never-navigable, so it must be checked independently of `relevant`.
    func testHiddenAppearanceQuestionsAreExcludedEvenWhenRelevant() {
        let questions = [
            makeQuestion(ref: "/data/name"),
            makeQuestion(ref: "/data/secret", relevant: true, hidden: true),
            makeQuestion(ref: "/data/c")
        ]
        let steps = QuestionFlowEngine.buildSteps(questions: questions, repeats: [])
        XCTAssertEqual(steps.map(\.id), ["q:/data/name[0]", "q:/data/c[0]", "finish"])
    }

    func testMissingRepeatSeriesIsSkippedRatherThanCrashing() {
        let questions = [
            makeQuestion(ref: "/data/g/r/item", index: 0, repeatRef: "/data/g/r", repeatIndex: 0, repeatCount: 1)
        ]
        let steps = QuestionFlowEngine.buildSteps(questions: questions, repeats: [])
        XCTAssertEqual(steps.map(\.id), ["q:/data/g/r/item[0]", "finish"])
    }

    /// The `.finish` step ("Send" / "Save Draft") is the whole point of this
    /// change: it must always be the true last step, reached only once every
    /// real question/group has been passed.
    func testFinishStepIsAlwaysAppendedLast() {
        let steps = QuestionFlowEngine.buildSteps(questions: [makeQuestion(ref: "/data/a")], repeats: [])
        XCTAssertEqual(steps.last, .finish)
    }

    func testFinishStepIsStillPresentEvenWithNoQuestionsAtAll() {
        let steps = QuestionFlowEngine.buildSteps(questions: [], repeats: [])
        XCTAssertEqual(steps, [.finish])
    }

    // MARK: - `field-list` groups (answered together, not one at a time)

    func testFieldListGroupQuestionsAreClusteredIntoOneStep() {
        let questions = [
            makeQuestion(ref: "/data/name"),
            makeQuestion(ref: "/data/g/a", fieldListGroupRef: "/data/g", fieldListGroupLabel: "Section G"),
            makeQuestion(ref: "/data/g/b", fieldListGroupRef: "/data/g", fieldListGroupLabel: "Section G"),
            makeQuestion(ref: "/data/after")
        ]
        let steps = QuestionFlowEngine.buildSteps(questions: questions, repeats: [])
        XCTAssertEqual(steps.map(\.id), ["q:/data/name[0]", "g:/data/g", "q:/data/after[0]", "finish"])

        guard case .questionGroup(let ref, let label, let grouped) = steps[1] else {
            return XCTFail("expected a questionGroup step")
        }
        XCTAssertEqual(ref, "/data/g")
        XCTAssertEqual(label, "Section G")
        XCTAssertEqual(grouped.map(\.ref), ["/data/g/a", "/data/g/b"])
    }

    func testFieldListGroupExcludesItsOwnIrrelevantMembersLikeAnyOtherQuestion() {
        let questions = [
            makeQuestion(ref: "/data/g/a", fieldListGroupRef: "/data/g"),
            makeQuestion(ref: "/data/g/b", relevant: false, fieldListGroupRef: "/data/g"),
            makeQuestion(ref: "/data/g/c", fieldListGroupRef: "/data/g")
        ]
        let steps = QuestionFlowEngine.buildSteps(questions: questions, repeats: [])
        XCTAssertEqual(steps.map(\.id), ["g:/data/g", "finish"])
        guard case .questionGroup(_, _, let grouped) = steps[0] else {
            return XCTFail("expected a questionGroup step")
        }
        XCTAssertEqual(grouped.map(\.ref), ["/data/g/a", "/data/g/c"], "the irrelevant member is dropped, same as a standalone question would be")
    }

    func testUngroupedQuestionsStayOneAtATimeAroundAFieldListGroup() {
        let questions = [
            makeQuestion(ref: "/data/before"),
            makeQuestion(ref: "/data/g/a", fieldListGroupRef: "/data/g"),
            makeQuestion(ref: "/data/after")
        ]
        let steps = QuestionFlowEngine.buildSteps(questions: questions, repeats: [])
        XCTAssertEqual(steps.map(\.id), ["q:/data/before[0]", "g:/data/g", "q:/data/after[0]", "finish"])
        XCTAssertEqual(steps[0], .question(questions[0]))
        XCTAssertEqual(steps[2], .question(questions[2]))
    }
}

final class QuestionFlowNavigatorTests: XCTestCase {
    private let steps: [QuestionFlowEngine.Step] = [
        .question(makeQuestion(ref: "/data/a")),
        .question(makeQuestion(ref: "/data/b")),
        .question(makeQuestion(ref: "/data/c"))
    ]

    func testStartsAtFirstStep() {
        let navigator = QuestionFlowNavigator(steps: steps)
        XCTAssertEqual(navigator.current?.id, "q:/data/a[0]")
        XCTAssertTrue(navigator.isAtStart)
        XCTAssertFalse(navigator.isAtEnd)
        XCTAssertEqual(navigator.progress.current, 1)
        XCTAssertEqual(navigator.progress.total, 3)
    }

    func testAdvanceMovesForwardAndStopsAtTheEnd() {
        var navigator = QuestionFlowNavigator(steps: steps)
        navigator.advance()
        navigator.advance()
        XCTAssertTrue(navigator.isAtEnd)
        XCTAssertEqual(navigator.current?.id, "q:/data/c[0]")
        navigator.advance()
        XCTAssertEqual(navigator.current?.id, "q:/data/c[0]", "advancing past the end should stay put")
    }

    func testRetreatMovesBackwardAndStopsAtTheStart() {
        var navigator = QuestionFlowNavigator(steps: steps, currentIndex: 1)
        navigator.retreat()
        XCTAssertTrue(navigator.isAtStart)
        navigator.retreat()
        XCTAssertTrue(navigator.isAtStart, "retreating past the start should stay put")
    }

    func testUpdateStepsKeepsPositionOnTheSameStepWhenItStillExists() {
        var navigator = QuestionFlowNavigator(steps: steps, currentIndex: 1)
        // A value changed elsewhere revealed a new question after /data/a.
        let newSteps: [QuestionFlowEngine.Step] = [
            .question(makeQuestion(ref: "/data/a")),
            .question(makeQuestion(ref: "/data/bonus")),
            .question(makeQuestion(ref: "/data/b")),
            .question(makeQuestion(ref: "/data/c"))
        ]
        navigator.updateSteps(newSteps)
        XCTAssertEqual(navigator.current?.id, "q:/data/b[0]", "should still be on /data/b, now at a new index")
        XCTAssertEqual(navigator.currentIndex, 2)
    }

    func testUpdateStepsClampsWhenTheCurrentStepNoLongerExists() {
        var navigator = QuestionFlowNavigator(steps: steps, currentIndex: 2)
        let newSteps: [QuestionFlowEngine.Step] = [
            .question(makeQuestion(ref: "/data/a")),
            .question(makeQuestion(ref: "/data/b"))
        ]
        navigator.updateSteps(newSteps)
        XCTAssertEqual(navigator.currentIndex, 1, "clamped to the new last valid index")
    }

    func testEmptyStepsReportsNoCurrentStepAndZeroProgress() {
        let navigator = QuestionFlowNavigator(steps: [])
        XCTAssertNil(navigator.current)
        XCTAssertEqual(navigator.progress.current, 0)
        XCTAssertEqual(navigator.progress.total, 0)
        XCTAssertTrue(navigator.isAtStart)
        XCTAssertTrue(navigator.isAtEnd)
    }
}
