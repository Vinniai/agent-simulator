import Testing
import Foundation
@testable import AgentSim

/// Source triangulation gets sharper when the JSX scanner sees not
/// just the hit element's label but the labels of the elements around
/// it on-screen. `contextBag(at:)` extracts that bag from the AX tree
/// — direct siblings of the deepest containing node, plus up to two
/// nearest labeled ancestors. Pure, no I/O.
@Suite("AXNode.contextBag")
struct AXNodeContextTests {

    /// Helper: rect at a position that doesn't matter for the bag, only
    /// for hit-test routing.
    private func frame(_ x: Double, _ y: Double, _ w: Double = 10, _ h: Double = 10) -> Rect {
        Rect(origin: Point(x: x, y: y), size: Size(width: w, height: h))
    }

    @Test("siblings + ancestor labels surface; hit's own label is omitted")
    func siblings_and_ancestors() {
        // Settings screen → "Notifications" row → tap the Switch (label "Off").
        // Expected bag: ["Notifications", "Settings"] — sibling text + ancestor screen.
        let hit = AXNode(role: "AXSwitch", label: "Off", frame: frame(50, 100))
        let siblingText = AXNode(role: "AXStaticText", label: "Notifications", frame: frame(10, 100))
        let row = AXNode(
            role: "AXGroup", label: nil,
            frame: Rect(origin: Point(x: 0, y: 100), size: Size(width: 200, height: 30)),
            children: [siblingText, hit]
        )
        let screen = AXNode(
            role: "AXGroup", label: "Settings",
            frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 400, height: 800)),
            children: [row]
        )
        let bag = screen.contextBag(at: Point(x: 55, y: 105))
        #expect(bag.contains("Notifications"))
        #expect(bag.contains("Settings"))
        #expect(!bag.contains("Off"))
    }

    @Test("ancestorDepth caps how far up we walk for labels")
    func ancestor_depth_cap() {
        // Three-deep labeled ancestors; default cap = 2 → top one excluded.
        let hit = AXNode(role: "AXButton", label: "Save", frame: frame(0, 0))
        let inner = AXNode(role: "AXGroup", label: "Card", frame: frame(0, 0, 100, 100), children: [hit])
        let middle = AXNode(role: "AXGroup", label: "Section", frame: frame(0, 0, 200, 200), children: [inner])
        let outer = AXNode(role: "AXGroup", label: "App", frame: frame(0, 0, 400, 400), children: [middle])
        let bag = outer.contextBag(at: Point(x: 5, y: 5))
        #expect(bag.contains("Card"))
        #expect(bag.contains("Section"))
        #expect(!bag.contains("App"))
    }

    @Test("nil / empty labels are skipped; values and identifiers join the bag")
    func includes_value_and_identifier() {
        let hit = AXNode(role: "AXButton", label: "Confirm", frame: frame(0, 0))
        let sibling = AXNode(
            role: "AXStaticText",
            label: nil, value: "$42.00", identifier: "total-amount",
            frame: frame(20, 0)
        )
        let parent = AXNode(
            role: "AXGroup", label: "",
            frame: frame(0, 0, 100, 100),
            children: [sibling, hit]
        )
        let bag = parent.contextBag(at: Point(x: 1, y: 1))
        #expect(bag.contains("$42.00"))
        #expect(bag.contains("total-amount"))
        // empty parent label doesn't pollute the bag
        #expect(!bag.contains(""))
    }

    @Test("bag is deduped")
    func deduped() {
        let hit = AXNode(role: "AXButton", label: "Go", frame: frame(0, 0))
        let s1 = AXNode(role: "AXStaticText", label: "Item", frame: frame(10, 0))
        let s2 = AXNode(role: "AXStaticText", label: "Item", frame: frame(20, 0))
        let parent = AXNode(role: "AXGroup", label: nil, frame: frame(0, 0, 100, 100), children: [s1, s2, hit])
        let bag = parent.contextBag(at: Point(x: 1, y: 1))
        #expect(bag.filter { $0 == "Item" }.count == 1)
    }

    @Test("returns empty bag when point misses the tree")
    func empty_outside() {
        let hit = AXNode(role: "AXButton", label: "X", frame: frame(0, 0))
        let root = AXNode(role: "AXGroup", label: "Root", frame: frame(0, 0, 10, 10), children: [hit])
        #expect(root.contextBag(at: Point(x: 999, y: 999)).isEmpty)
    }
}
