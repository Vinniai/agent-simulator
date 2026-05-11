import Foundation

/// Two-leg accessibility port: try `primary` first, fall back to
/// `fallback` whenever the primary returns `nil` or throws. Used so
/// production callers get the native AXPTranslator path when it
/// works, and the argent-subprocess path when it doesn't (tooling
/// running outside Simulator.app, missing private frameworks, an
/// AX dispatcher that hasn't bridged yet).
///
/// Pure composition over the existing `Accessibility` port — adds no
/// behaviour of its own beyond the prefer-primary / on-empty-or-error
/// fallback rule. Tests drive it with `MockAccessibility` for both
/// legs.
final class CompositeAccessibility: Accessibility, @unchecked Sendable {
    private let primary: any Accessibility
    private let fallback: any Accessibility

    init(primary: any Accessibility, fallback: any Accessibility) {
        self.primary = primary
        self.fallback = fallback
    }

    func describeAll() throws -> AXNode? {
        if let tree = try? primary.describeAll(), tree != nil {
            return tree
        }
        return try fallback.describeAll()
    }

    func describeAt(point: Point) throws -> AXNode? {
        if let node = try? primary.describeAt(point: point), node != nil {
            return node
        }
        return try fallback.describeAt(point: point)
    }
}
