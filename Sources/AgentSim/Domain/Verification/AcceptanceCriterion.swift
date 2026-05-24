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
struct ElementSelector: Equatable, Sendable {
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
enum Expectation: Equatable, Sendable {
    case exists
    case absent
    case enabled
    case disabled
    case textEquals(String)
    case textContains(String)
}

/// A machine-verifiable assertion a ``ReviewTask`` must satisfy: an
/// ``ElementSelector`` plus an ``Expectation``, checked against an AX
/// tree to produce a ``Verdict``.
struct AcceptanceCriterion: Equatable, Sendable {
    var description: String
    var selector: ElementSelector
    var expect: Expectation

    init(description: String, selector: ElementSelector, expect: Expectation) {
        self.description = description
        self.selector = selector
        self.expect = expect
    }
}

/// The outcome of checking one ``AcceptanceCriterion`` against a tree.
struct Verdict: Equatable, Sendable {
    enum Outcome: String, Equatable, Sendable {
        case pass, fail, ambiguous
    }
    let criterion: AcceptanceCriterion
    let outcome: Outcome
    /// Why it failed or was ambiguous; `nil` on pass.
    let reason: String?
}
