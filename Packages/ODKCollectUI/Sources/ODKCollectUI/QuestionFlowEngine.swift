import ODKWebEngine

/// Turns the headless engine's flat `[Question]` + `[RepeatSeries]` snapshot into a
/// navigable sequence: irrelevant questions are skipped entirely; consecutive
/// questions sharing the same `field-list` group ref are clustered into one
/// `.questionGroup` step (answered together, on one page); everything else is
/// navigated one question at a time; an "add another" step is inserted right after
/// the last question of the last instance of each repeat series; a final `.finish`
/// step is always appended last, offering "Send" or "Save Draft" once every real
/// question/group has been answered.
public enum QuestionFlowEngine {
    public enum Step: Identifiable, Equatable {
        case question(Question)
        /// A `field-list` group's page — every question in `questions` is answered
        /// together, not one at a time. `ref` is the group's own model ref (stable
        /// across relevance changes, unlike the member list); `label` is the
        /// group's own `<label>`, if it has one.
        case questionGroup(ref: String, label: String?, questions: [Question])
        case addRepeat(RepeatSeries)
        /// The last step, always — reached only once every real question/group
        /// has been answered and validated. Offers "Send" or "Save Draft" as two
        /// explicit choices, rather than folding "send" into the last question's
        /// own advance button.
        case finish

        public var id: String {
            switch self {
            case .question(let question): return "q:\(question.uid)"
            case .questionGroup(let ref, _, _): return "g:\(ref)"
            case .addRepeat(let series): return "r:\(series.ref)"
            case .finish: return "finish"
            }
        }
    }

    public static func buildSteps(questions: [Question], repeats: [RepeatSeries]) -> [Step] {
        // `hidden` (appearance="hidden") is a static "never show this" marker,
        // distinct from `relevant` — both must hold for a question to be navigable.
        let relevant = questions.filter { $0.relevant && !$0.hidden }
        var steps: [Step] = []
        var offset = 0

        while offset < relevant.count {
            let question = relevant[offset]

            guard let groupRef = question.fieldListGroupRef else {
                steps.append(.question(question))
                appendAddRepeatStepIfNeeded(for: question, at: offset, in: relevant, repeats: repeats, into: &steps)
                offset += 1
                continue
            }

            // A field-list group's members are always contiguous in `relevant` —
            // they're declared consecutively in the XForm body, and filtering by
            // relevance only removes entries, never reorders them.
            var groupQuestions: [Question] = []
            var groupLabel: String?
            let lastMemberOffset = { () -> Int in
                var end = offset
                while end < relevant.count, relevant[end].fieldListGroupRef == groupRef {
                    groupQuestions.append(relevant[end])
                    groupLabel = groupLabel ?? relevant[end].fieldListGroupLabel
                    end += 1
                }
                return end - 1
            }()

            steps.append(.questionGroup(ref: groupRef, label: groupLabel, questions: groupQuestions))
            if let lastMember = groupQuestions.last {
                appendAddRepeatStepIfNeeded(for: lastMember, at: lastMemberOffset, in: relevant, repeats: repeats, into: &steps)
            }
            offset = lastMemberOffset + 1
        }

        steps.append(.finish)
        return steps
    }

    private static func appendAddRepeatStepIfNeeded(
        for question: Question,
        at offset: Int,
        in relevant: [Question],
        repeats: [RepeatSeries],
        into steps: inout [Step]
    ) {
        guard
            let repeatRef = question.repeatRef,
            let repeatIndex = question.repeatIndex,
            let repeatCount = question.repeatCount,
            repeatIndex == repeatCount - 1
        else {
            return
        }

        let next = offset + 1 < relevant.count ? relevant[offset + 1] : nil
        let stillInSameInstance = next?.repeatRef == repeatRef && next?.repeatIndex == repeatIndex
        guard !stillInSameInstance else { return }

        if let series = repeats.first(where: { $0.ref == repeatRef }) {
            steps.append(.addRepeat(series))
        }
    }
}

/// Tracks the user's current position in a `QuestionFlowEngine` step sequence, and
/// keeps that position stable (by step identity) as the sequence is rebuilt after
/// answers change relevance or repeat counts.
public struct QuestionFlowNavigator: Equatable {
    public private(set) var steps: [QuestionFlowEngine.Step]
    public private(set) var currentIndex: Int

    public init(steps: [QuestionFlowEngine.Step] = [], currentIndex: Int = 0) {
        self.steps = steps
        self.currentIndex = Self.clamp(currentIndex, to: steps)
    }

    public var current: QuestionFlowEngine.Step? {
        steps.indices.contains(currentIndex) ? steps[currentIndex] : nil
    }

    public var isAtStart: Bool { currentIndex == 0 }
    public var isAtEnd: Bool { steps.isEmpty || currentIndex == steps.count - 1 }

    /// 1-based `(current, total)`, for a "Question 3 of 12" indicator.
    public var progress: (current: Int, total: Int) {
        (steps.isEmpty ? 0 : currentIndex + 1, steps.count)
    }

    public mutating func advance() {
        currentIndex = Self.clamp(currentIndex + 1, to: steps)
    }

    public mutating func retreat() {
        currentIndex = Self.clamp(currentIndex - 1, to: steps)
    }

    /// Replaces the step list — e.g. after `setValue` changes another question's
    /// relevance, or a repeat instance is added/removed — while keeping the user on
    /// the same step if it still exists, otherwise clamping to the nearest valid one.
    public mutating func updateSteps(_ newSteps: [QuestionFlowEngine.Step]) {
        let currentID = current?.id
        steps = newSteps
        if let currentID, let index = steps.firstIndex(where: { $0.id == currentID }) {
            currentIndex = index
        } else {
            currentIndex = Self.clamp(currentIndex, to: steps)
        }
    }

    private static func clamp(_ index: Int, to steps: [QuestionFlowEngine.Step]) -> Int {
        guard !steps.isEmpty else { return 0 }
        return min(max(index, 0), steps.count - 1)
    }
}
