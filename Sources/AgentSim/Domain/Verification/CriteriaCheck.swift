import Foundation

/// Pure verdict engine for first-class Acceptance Criteria (ADR-0002).
/// Given an AX tree and a list of criteria, returns one ``Verdict`` per
/// criterion in input order — no I/O, no simulator. The caller decides
/// where the tree comes from (a captured snapshot's `axPath` by default,
/// or live `describe-ui`); this engine only sees the value.
enum CriteriaCheck {
    static func run(tree: AXNode, criteria: [AcceptanceCriterion]) -> [Verdict] {
        criteria.map { verdict(for: $0, in: tree) }
    }

    private static func verdict(for c: AcceptanceCriterion, in tree: AXNode) -> Verdict {
        let matches = collect(c.selector, in: tree)
        switch c.expect {
        case .exists:
            return matches.isEmpty
                ? Verdict(criterion: c, outcome: .fail, reason: "no element matched \(c.selector.describe)")
                : Verdict(criterion: c, outcome: .pass, reason: nil)
        case .absent:
            return matches.isEmpty
                ? Verdict(criterion: c, outcome: .pass, reason: nil)
                : Verdict(criterion: c, outcome: .fail,
                          reason: "expected no match but found \(matches.count) for \(c.selector.describe)")
        case .enabled, .disabled, .textEquals, .textContains:
            // Element-level expectations need exactly one match to be decidable.
            guard matches.count == 1 else {
                if matches.isEmpty {
                    return Verdict(criterion: c, outcome: .fail,
                                   reason: "no element matched \(c.selector.describe)")
                }
                return Verdict(criterion: c, outcome: .ambiguous,
                               reason: "\(matches.count) elements matched \(c.selector.describe)")
            }
            return elementVerdict(c, node: matches[0])
        }
    }

    private static func elementVerdict(_ c: AcceptanceCriterion, node: AXNode) -> Verdict {
        switch c.expect {
        case .enabled:
            return node.enabled
                ? Verdict(criterion: c, outcome: .pass, reason: nil)
                : Verdict(criterion: c, outcome: .fail, reason: "element is disabled")
        case .disabled:
            return !node.enabled
                ? Verdict(criterion: c, outcome: .pass, reason: nil)
                : Verdict(criterion: c, outcome: .fail, reason: "element is enabled")
        case .textEquals(let expected):
            let hit = node.label == expected || node.value == expected
            return hit
                ? Verdict(criterion: c, outcome: .pass, reason: nil)
                : Verdict(criterion: c, outcome: .fail,
                          reason: "text is label=\(node.label ?? "nil") value=\(node.value ?? "nil"), expected ==\(expected)")
        case .textContains(let needle):
            let hit = (node.label?.contains(needle) ?? false) || (node.value?.contains(needle) ?? false)
            return hit
                ? Verdict(criterion: c, outcome: .pass, reason: nil)
                : Verdict(criterion: c, outcome: .fail,
                          reason: "text is label=\(node.label ?? "nil") value=\(node.value ?? "nil"), expected to contain \(needle)")
        case .exists, .absent:
            // Unreachable: existence handled before delegating here.
            return Verdict(criterion: c, outcome: .fail, reason: "internal: existence routed to elementVerdict")
        }
    }

    /// Depth-first pre-order collection of every node the selector matches.
    private static func collect(_ selector: ElementSelector, in root: AXNode) -> [AXNode] {
        var out: [AXNode] = []
        func recurse(_ n: AXNode) {
            if selector.matches(n) { out.append(n) }
            for child in n.children { recurse(child) }
        }
        recurse(root)
        return out
    }
}
