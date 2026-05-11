import Foundation

/// `Accessibility` adapter over the `argent run describe --json`
/// subprocess. Wraps the existing `ArgentAccessibilityFallback`
/// one-shot fetch + the pure `AXNode.hitTest` post-fetch transform
/// behind the standard port shape, so it can be composed with the
/// native `AXPTranslatorAccessibility` via `CompositeAccessibility`.
final class ArgentAccessibility: Accessibility, @unchecked Sendable {
    private let udid: String

    init(udid: String) {
        self.udid = udid
    }

    func describeAll() throws -> AXNode? {
        try ArgentAccessibilityFallback.describeAll(udid: udid)
    }

    func describeAt(point: Point) throws -> AXNode? {
        guard let tree = try describeAll() else { return nil }
        return tree.hitTest(point) ?? tree
    }
}
