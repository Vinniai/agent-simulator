import Foundation

/// Names an on-screen element for an ``AcceptanceCriterion``. Whatever
/// fields are set are ANDed; an all-nil selector matches nothing (so it
/// can never accidentally select the whole tree). The recommended
/// primary key is `identifier` — an `accessibilityIdentifier` / React
/// Native `testID` — which is stable across re-renders and copy changes,
/// unlike a visible label.
///
/// Named `ElementSelector` rather than the glossary term "Selector" to
/// avoid colliding with `ObjectiveC.Selector`, which Foundation pulls
/// into scope everywhere.
struct ElementSelector: Equatable, Sendable, Codable {
    var identifier: String?
    var role: String?
    var label: String?
    /// Substring expected within the element's `label` or `value`.
    var text: String?

    init(identifier: String? = nil, role: String? = nil, label: String? = nil, text: String? = nil) {
        self.identifier = identifier
        self.role = role
        self.label = label
        self.text = text
    }

    /// True when every *set* field matches `node`; unset fields don't
    /// constrain. An empty selector matches nothing.
    func matches(_ node: AXNode) -> Bool {
        if identifier == nil && role == nil && label == nil && text == nil { return false }
        if let identifier, node.identifier != identifier { return false }
        if let role, node.role != role { return false }
        if let label, node.label != label { return false }
        if let text {
            let inLabel = node.label?.contains(text) ?? false
            let inValue = node.value?.contains(text) ?? false
            if !inLabel && !inValue { return false }
        }
        return true
    }

    /// Compact human description used in `Verdict` reasons.
    var describe: String {
        var parts: [String] = []
        if let identifier { parts.append("identifier=\(identifier)") }
        if let role { parts.append("role=\(role)") }
        if let label { parts.append("label=\(label)") }
        if let text { parts.append("text~=\(text)") }
        return parts.isEmpty ? "<empty selector>" : parts.joined(separator: " ")
    }
}

/// What an ``AcceptanceCriterion`` asserts about its selected element.
/// Minimal-but-complete (ADR-0002): existence checks are count-based;
/// the element-level checks (`enabled`/`disabled`/`text…`) require a
/// single match and are otherwise ambiguous.
///
/// Named `ExpectedState` rather than the glossary term "expectation" to
/// avoid colliding with `Testing.Expectation` (the `#expect` result type),
/// which is in scope in every test file — the same collision that forced
/// `ElementSelector`. Encodes to a `kind`-tagged object
/// (`{"kind":"textEquals","text":"Done"}`) so authored JSON stays legible,
/// rather than Swift's default `{"textEquals":{"_0":"Done"}}`.
enum ExpectedState: Equatable, Sendable, Codable {
    case exists
    case absent
    case enabled
    case disabled
    case textEquals(String)
    case textContains(String)

    private enum CodingKeys: String, CodingKey { case kind, text }
    private enum Kind: String, Codable {
        case exists, absent, enabled, disabled, textEquals, textContains
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .exists: try c.encode(Kind.exists, forKey: .kind)
        case .absent: try c.encode(Kind.absent, forKey: .kind)
        case .enabled: try c.encode(Kind.enabled, forKey: .kind)
        case .disabled: try c.encode(Kind.disabled, forKey: .kind)
        case .textEquals(let t):
            try c.encode(Kind.textEquals, forKey: .kind)
            try c.encode(t, forKey: .text)
        case .textContains(let t):
            try c.encode(Kind.textContains, forKey: .kind)
            try c.encode(t, forKey: .text)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .exists: self = .exists
        case .absent: self = .absent
        case .enabled: self = .enabled
        case .disabled: self = .disabled
        case .textEquals: self = .textEquals(try c.decode(String.self, forKey: .text))
        case .textContains: self = .textContains(try c.decode(String.self, forKey: .text))
        }
    }
}

/// A machine-verifiable assertion a ``ReviewTask`` must satisfy: an
/// ``ElementSelector`` plus an ``Expectation``, checked against an AX
/// tree to produce a ``Verdict``.
struct AcceptanceCriterion: Equatable, Sendable, Codable {
    var description: String
    var selector: ElementSelector
    var expect: ExpectedState

    init(description: String, selector: ElementSelector, expect: ExpectedState) {
        self.description = description
        self.selector = selector
        self.expect = expect
    }
}

/// The outcome of checking one ``AcceptanceCriterion`` against a tree.
struct Verdict: Equatable, Sendable, Codable {
    enum Outcome: String, Equatable, Sendable, Codable {
        case pass, fail, ambiguous
    }
    let criterion: AcceptanceCriterion
    let outcome: Outcome
    /// Why it failed or was ambiguous; `nil` on pass.
    let reason: String?
}
