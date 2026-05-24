import Testing
import Foundation
import Mockable
@testable import AgentSim

/// `Triangulate` glues the AX hit-test to workspace discovery so a
/// single call returns "what's under this point AND which project
/// tree did it come from". Source candidates stay empty in Phase A —
/// they arrive once the JSX scanner (Phase B) and React DevTools
/// (Phase C) collaborators land.
@Suite("Triangulate")
struct TriangulateTests {

    private func sampleNode() -> AXNode {
        AXNode(
            role: "AXButton", label: "Done",
            frame: Rect(origin: Point(x: 100, y: 200),
                        size: Size(width: 80, height: 44))
        )
    }

    @Test("returns the AX hit plus the discovered workspace")
    func happy_path() async throws {
        let ax = MockAccessibility()
        let metro = MockMetro()
        let hit = sampleNode()
        let root = URL(fileURLWithPath: "/Users/dev/taskr")
        given(ax).describeAll().willReturn(hit)
        given(metro).projectRoot().willReturn(root)

        let result = try await Triangulate.run(
            point: Point(x: 110, y: 220),
            accessibility: ax,
            metro: metro,
            readFile: { _ in #"{"dependencies":{"expo-router":"3.0"}}"# }
        )

        #expect(result.node == hit)
        #expect(result.workspace == Workspace(root: root, framework: .expoRouter))
        #expect(result.candidates.isEmpty)
    }

    @Test("returns the AX hit with nil workspace when Metro is unreachable")
    func no_metro_yields_nil_workspace() async throws {
        let ax = MockAccessibility()
        let metro = MockMetro()
        let hit = sampleNode()
        given(ax).describeAll().willReturn(hit)
        given(metro).projectRoot().willReturn(nil)

        let result = try await Triangulate.run(
            point: Point(x: 110, y: 220),
            accessibility: ax,
            metro: metro,
            readFile: { _ in nil }
        )

        #expect(result.node == hit)
        #expect(result.workspace == nil)
        #expect(result.candidates.isEmpty)
    }

    @Test("AX siblings + ancestors flow into JSXScanner as a context bag")
    func context_bag_flows_through() async throws {
        // Build a tree where the tap hits a Switch labeled "Off" sitting
        // next to "Notifications" inside a "Settings" group. Expect the
        // file that mentions "Notifications" near `<Text>Off</Text>` to
        // outrank a file with the same `Off` in isolation.
        let ax = MockAccessibility()
        let metro = MockMetro()
        let hit = AXNode(
            role: "AXSwitch", label: "Off",
            frame: Rect(origin: Point(x: 100, y: 100), size: Size(width: 40, height: 30))
        )
        let sibling = AXNode(
            role: "AXStaticText", label: "Notifications",
            frame: Rect(origin: Point(x: 10, y: 100), size: Size(width: 80, height: 30))
        )
        let row = AXNode(
            role: "AXGroup", label: "Settings",
            frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 400, height: 400)),
            children: [sibling, hit]
        )
        let root = URL(fileURLWithPath: "/ws")
        let aFile = root.appendingPathComponent("app/a.tsx")
        let bFile = root.appendingPathComponent("app/b.tsx")
        given(ax).describeAll().willReturn(row)
        given(metro).projectRoot().willReturn(root)

        let result = try await Triangulate.run(
            point: Point(x: 110, y: 110),
            accessibility: ax,
            metro: metro,
            listFiles: { _ in [aFile, bFile] },
            readFile: { url in
                if url == aFile { return "<Text>Off</Text>" }
                if url == bFile {
                    return """
                    // Settings screen
                    <Row>
                      <Text>Notifications</Text>
                      <Text>Off</Text>
                    </Row>
                    """
                }
                return #"{"dependencies":{"expo-router":"3.0"}}"#
            }
        )
        #expect(result.node == hit)
        #expect(result.candidates.count == 2)
        #expect(result.candidates[0].file == bFile)
        #expect(result.candidates[0].confidence > result.candidates[1].confidence)
    }

    @Test("returns nil node when AX has no hit at the point")
    func ax_miss_yields_nil_node() async throws {
        let ax = MockAccessibility()
        let metro = MockMetro()
        given(ax).describeAll().willReturn(nil)
        given(metro).projectRoot().willReturn(URL(fileURLWithPath: "/tmp/p"))

        let result = try await Triangulate.run(
            point: Point(x: 0, y: 0),
            accessibility: ax,
            metro: metro,
            readFile: { _ in "" }
        )

        #expect(result.node == nil)
        #expect(result.workspace?.framework == .unknown)
    }
}
