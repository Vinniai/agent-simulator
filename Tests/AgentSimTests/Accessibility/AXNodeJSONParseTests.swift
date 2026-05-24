import Testing
import Foundation
@testable import AgentSim

/// Verification reads a captured AX snapshot artifact (the file at a
/// snapshot's `axPath`), which is exactly `AXNode.json`. `AXNode.from(json:)`
/// is the inverse of that projection — a pure parser that round-trips the
/// `.json` shape (flat `frame{x,y,width,height}`, explicit nulls, nested
/// `children`) back into a value, so the verify use-case can run against a
/// snapshot without a simulator.
@Suite("AXNode JSON parse")
struct AXNodeJSONParseTests {

    private func frame(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Rect {
        Rect(origin: Point(x: x, y: y), size: Size(width: w, height: h))
    }

    @Test("round-trips a full tree through json and back")
    func roundtrip() throws {
        let node = AXNode(
            role: "AXWindow", subrole: "AXDialog", label: "New Task",
            value: nil, identifier: "win-1", title: "T", help: nil,
            frame: frame(0, 0, 400, 800), enabled: true, focused: false, hidden: false,
            children: [
                AXNode(role: "AXButton", label: "Save", identifier: "save-btn",
                       frame: frame(10, 10, 80, 40), enabled: true),
                AXNode(role: "AXStaticText", label: "Name required",
                       frame: frame(10, 60, 200, 20), enabled: false),
            ])

        let parsed = try #require(AXNode.from(json: Data(node.json.utf8)))
        #expect(parsed == node)
    }

    @Test("missing/explicit-null optionals decode as nil and defaults apply")
    func nullsAndDefaults() throws {
        let json = """
        {"role":"AXButton","subrole":null,"label":"Go","value":null,
         "identifier":null,"title":null,"help":null,
         "frame":{"x":1,"y":2,"width":3,"height":4},
         "enabled":true,"focused":false,"hidden":false,"children":[]}
        """
        let parsed = try #require(AXNode.from(json: Data(json.utf8)))
        #expect(parsed.role == "AXButton")
        #expect(parsed.label == "Go")
        #expect(parsed.subrole == nil)
        #expect(parsed.frame == frame(1, 2, 3, 4))
        #expect(parsed.children.isEmpty)
    }

    @Test("returns nil on non-object / garbage input")
    func garbage() {
        #expect(AXNode.from(json: Data("not json".utf8)) == nil)
        #expect(AXNode.from(json: Data("[1,2,3]".utf8)) == nil)
    }
}
