import Foundation

/// One question from the form, as reported by the headless engine's `getQuestions()`
/// bridge call. Labels/hints/options are effectively static; `relevant`/`value` reflect
/// the model's current state and change as answers are entered.
public struct Question: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case string, int, decimal
        case select1, select
        case date, time, dateTime
        case note, trigger, range, rank
        case geopoint, geotrace, geoshape
        case signature, binaryImage, binaryAudio, binaryVideo, binaryFile
        /// A `data-type-xml` this app doesn't specifically recognize yet — rendered as
        /// plain text so the form can still be filled rather than dead-ending.
        case unsupported
    }

    public struct Option: Codable, Equatable, Sendable {
        public let value: String
        public let label: String

        public init(value: String, label: String) {
            self.value = value
            self.label = label
        }
    }

    public let ref: String
    public let index: Int
    /// Stable identity across question-list refreshes: `"\(ref)[\(index)]"`.
    public let uid: String
    public let typeXml: String
    public let kind: Kind
    public let label: String
    public let hint: String?
    public let required: Bool
    public let relevant: Bool
    public let readonly: Bool
    /// `true` for `appearance="hidden"` fields — the standard XLSForm/ODK convention
    /// for a value that must never be shown to the user (e.g. calculated or
    /// externally-set data that still needs a body binding). Distinct from
    /// `relevant`, which is dynamic; this is a static, always-skip marker.
    public let hidden: Bool
    /// `true` for `date` fields with `appearance="bikram-sambat"` — the ODK/XLSForm
    /// convention for filling in a date using Nepal's Bikram Sambat calendar while
    /// still storing a plain Gregorian `value`.
    public let bikramSambat: Bool
    public let value: String
    public let options: [Option]
    public let rangeMin: Double?
    public let rangeMax: Double?
    public let rangeStep: Double?
    public let repeatRef: String?
    public let repeatIndex: Int?
    public let repeatCount: Int?
    /// The nearest ancestor `<group appearance="field-list">`'s ref, if any — the
    /// ODK/XLSForm convention for a cluster of questions meant to be answered
    /// together on one page, rather than one at a time. `nil` for a question not
    /// inside such a group (including inside a `field-list` *repeat*, which keeps
    /// its own one-instance-at-a-time navigation instead — see
    /// `QuestionFlowEngine`). Distinct from `repeatRef`.
    public let fieldListGroupRef: String?
    /// The field-list group's own label, if it has one — shown once above every
    /// question clustered under `fieldListGroupRef`.
    public let fieldListGroupLabel: String?

    public var id: String { uid }

    public init(
        ref: String,
        index: Int,
        uid: String,
        typeXml: String,
        kind: Kind,
        label: String,
        hint: String?,
        required: Bool,
        relevant: Bool,
        readonly: Bool,
        hidden: Bool = false,
        bikramSambat: Bool = false,
        value: String,
        options: [Option],
        rangeMin: Double?,
        rangeMax: Double?,
        rangeStep: Double?,
        repeatRef: String?,
        repeatIndex: Int?,
        repeatCount: Int?,
        fieldListGroupRef: String? = nil,
        fieldListGroupLabel: String? = nil
    ) {
        self.ref = ref
        self.index = index
        self.uid = uid
        self.typeXml = typeXml
        self.kind = kind
        self.label = label
        self.hint = hint
        self.required = required
        self.relevant = relevant
        self.readonly = readonly
        self.hidden = hidden
        self.bikramSambat = bikramSambat
        self.value = value
        self.options = options
        self.rangeMin = rangeMin
        self.rangeMax = rangeMax
        self.rangeStep = rangeStep
        self.repeatRef = repeatRef
        self.repeatIndex = repeatIndex
        self.repeatCount = repeatCount
        self.fieldListGroupRef = fieldListGroupRef
        self.fieldListGroupLabel = fieldListGroupLabel
    }

    enum CodingKeys: String, CodingKey {
        case ref, index, uid, typeXml, kind, label, hint, required, relevant, readonly, hidden, bikramSambat, value, options
        case rangeMin, rangeMax, rangeStep, repeatRef, repeatIndex, repeatCount, fieldListGroupRef, fieldListGroupLabel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ref = try container.decode(String.self, forKey: .ref)
        index = try container.decode(Int.self, forKey: .index)
        uid = try container.decode(String.self, forKey: .uid)
        typeXml = try container.decode(String.self, forKey: .typeXml)
        kind = (try? container.decode(Kind.self, forKey: .kind)) ?? .unsupported
        label = try container.decode(String.self, forKey: .label)
        hint = try container.decodeIfPresent(String.self, forKey: .hint)
        required = try container.decode(Bool.self, forKey: .required)
        relevant = try container.decode(Bool.self, forKey: .relevant)
        readonly = try container.decode(Bool.self, forKey: .readonly)
        // Decoded leniently (defaulting to `false`) so a cached/older bridge.js build
        // that hasn't shipped this field yet doesn't fail decoding the whole question.
        hidden = (try? container.decodeIfPresent(Bool.self, forKey: .hidden)) ?? false
        bikramSambat = (try? container.decodeIfPresent(Bool.self, forKey: .bikramSambat)) ?? false
        value = try container.decode(String.self, forKey: .value)
        options = try container.decodeIfPresent([Option].self, forKey: .options) ?? []
        rangeMin = Question.decodeLooseDouble(container, .rangeMin)
        rangeMax = Question.decodeLooseDouble(container, .rangeMax)
        rangeStep = Question.decodeLooseDouble(container, .rangeStep)
        repeatRef = try container.decodeIfPresent(String.self, forKey: .repeatRef)
        repeatIndex = try container.decodeIfPresent(Int.self, forKey: .repeatIndex)
        repeatCount = try container.decodeIfPresent(Int.self, forKey: .repeatCount)
        fieldListGroupRef = try container.decodeIfPresent(String.self, forKey: .fieldListGroupRef)
        fieldListGroupLabel = try container.decodeIfPresent(String.self, forKey: .fieldListGroupLabel)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ref, forKey: .ref)
        try container.encode(index, forKey: .index)
        try container.encode(uid, forKey: .uid)
        try container.encode(typeXml, forKey: .typeXml)
        try container.encode(kind, forKey: .kind)
        try container.encode(label, forKey: .label)
        try container.encodeIfPresent(hint, forKey: .hint)
        try container.encode(required, forKey: .required)
        try container.encode(relevant, forKey: .relevant)
        try container.encode(readonly, forKey: .readonly)
        try container.encode(hidden, forKey: .hidden)
        try container.encode(bikramSambat, forKey: .bikramSambat)
        try container.encode(value, forKey: .value)
        try container.encode(options, forKey: .options)
        try container.encodeIfPresent(rangeMin, forKey: .rangeMin)
        try container.encodeIfPresent(rangeMax, forKey: .rangeMax)
        try container.encodeIfPresent(rangeStep, forKey: .rangeStep)
        try container.encodeIfPresent(repeatRef, forKey: .repeatRef)
        try container.encodeIfPresent(repeatIndex, forKey: .repeatIndex)
        try container.encodeIfPresent(repeatCount, forKey: .repeatCount)
        try container.encodeIfPresent(fieldListGroupRef, forKey: .fieldListGroupRef)
        try container.encodeIfPresent(fieldListGroupLabel, forKey: .fieldListGroupLabel)
    }

    /// `rangeMin`/`rangeMax`/`rangeStep` arrive from JS as HTML attribute strings
    /// (e.g. `"0"`), not JSON numbers — decode leniently from either.
    private static func decodeLooseDouble(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let string = try? container.decodeIfPresent(String.self, forKey: key) ?? nil {
            return Double(string)
        }
        return nil
    }
}

/// One repeat group's "add another" affordance, as reported by `getQuestions()`.
public struct RepeatSeries: Codable, Identifiable, Equatable, Sendable {
    public let ref: String
    public let label: String
    public let count: Int

    public var id: String { ref }

    public init(ref: String, label: String, count: Int) {
        self.ref = ref
        self.label = label
        self.count = count
    }
}
