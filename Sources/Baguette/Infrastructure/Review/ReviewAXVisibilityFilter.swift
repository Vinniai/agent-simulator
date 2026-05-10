import Foundation

enum ReviewAXVisibilityFilter {
    static func visibleTree(_ root: AXNode) -> AXNode {
        prune(root, parentFrame: root.frame)
    }

    private static func prune(_ node: AXNode, parentFrame: Rect) -> AXNode {
        let visibleChildren = node.children
            .filter { isVisible($0) }
            .map { prune($0, parentFrame: node.frame) }

        let topChildren: [AXNode]
        if let drawerChildren = leadingDrawerChildren(in: visibleChildren, parentFrame: node.frame) {
            topChildren = drawerChildren
        } else if let overlayIndex = strongestOverlayIndex(in: visibleChildren, parentFrame: node.frame) {
            topChildren = Array(visibleChildren[overlayIndex...])
        } else {
            topChildren = removeObscuredSiblings(visibleChildren)
        }

        return AXNode(
            role: node.role,
            subrole: node.subrole,
            label: node.label,
            value: node.value,
            identifier: node.identifier,
            title: node.title,
            help: node.help,
            frame: node.frame,
            enabled: node.enabled,
            focused: node.focused,
            hidden: node.hidden,
            children: topChildren
        )
    }

    private static func strongestOverlayIndex(in children: [AXNode], parentFrame: Rect) -> Int? {
        var match: Int?
        for (index, child) in children.enumerated() {
            if isOverlayLike(child, parentFrame: parentFrame) {
                match = index
            }
        }
        return match
    }

    private static func leadingDrawerChildren(in children: [AXNode], parentFrame: Rect) -> [AXNode]? {
        guard let backdrop = children.first,
              isUnlabelledBackdrop(backdrop, parentFrame: parentFrame),
              let firstContent = children.dropFirst().first(where: hasContent) else {
            return nil
        }

        let panelMinX = firstContent.frame.origin.x - 8
        var top: [AXNode] = []
        for child in children.dropFirst() {
            if !top.isEmpty && child.frame.origin.x < panelMinX {
                break
            }
            top.append(child)
        }
        return top.count >= 2 ? top : nil
    }

    private static func removeObscuredSiblings(_ children: [AXNode]) -> [AXNode] {
        children.enumerated().compactMap { index, child in
            let obscured = children.dropFirst(index + 1).contains { later in
                coverage(of: child.frame, by: later.frame) >= 0.92
            }
            return obscured ? nil : child
        }
    }

    private static func isOverlayLike(_ node: AXNode, parentFrame: Rect) -> Bool {
        let text = [
            node.role, node.subrole, node.label, node.value,
            node.identifier, node.title, node.help
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()

        let namedOverlay = [
            "alert", "dialog", "modal", "sheet", "popover",
            "menu", "action sheet", "presentation"
        ].contains { text.contains($0) }
        guard namedOverlay else { return false }

        let parentArea = area(parentFrame)
        guard parentArea > 0 else { return true }
        let ratio = area(node.frame) / parentArea
        return ratio > 0.03
    }

    private static func isUnlabelledBackdrop(_ node: AXNode, parentFrame: Rect) -> Bool {
        let hasText = [node.label, node.value, node.identifier, node.title, node.help]
            .contains { ($0?.isEmpty == false) }
        return !hasText && coverage(of: parentFrame, by: node.frame) >= 0.85
    }

    private static func hasContent(_ node: AXNode) -> Bool {
        [node.label, node.value, node.identifier, node.title, node.help]
            .contains { ($0?.isEmpty == false) }
    }

    private static func isVisible(_ node: AXNode) -> Bool {
        !node.hidden && node.frame.size.width > 0 && node.frame.size.height > 0
    }

    private static func coverage(of covered: Rect, by covering: Rect) -> Double {
        let coveredArea = area(covered)
        guard coveredArea > 0 else { return 0 }
        return intersectionArea(covered, covering) / coveredArea
    }

    private static func area(_ rect: Rect) -> Double {
        max(0, rect.size.width) * max(0, rect.size.height)
    }

    private static func intersectionArea(_ a: Rect, _ b: Rect) -> Double {
        let minX = max(a.origin.x, b.origin.x)
        let minY = max(a.origin.y, b.origin.y)
        let maxX = min(a.origin.x + a.size.width, b.origin.x + b.size.width)
        let maxY = min(a.origin.y + a.size.height, b.origin.y + b.size.height)
        return max(0, maxX - minX) * max(0, maxY - minY)
    }
}
