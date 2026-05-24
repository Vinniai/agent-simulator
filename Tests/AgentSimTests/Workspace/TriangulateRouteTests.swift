import Testing
import Foundation
import Mockable
@testable import AgentSim

/// Server-handler tests for the `/triangulate` POST. Follows the same
/// "pure JSON-string helper" shape used by `NotesRouteTests` so the
/// route closure stays a thin shim. Phase A: the response carries the
/// AX hit + discovered workspace; candidates are `[]` until the JSX
/// scanner (Phase B) and React DevTools fiber (Phase C) collaborators
/// land.
@Suite("Server /triangulate route")
struct TriangulateRouteTests {

    private func sampleNode() -> AXNode {
        AXNode(
            role: "AXButton", label: "Done",
            frame: Rect(origin: Point(x: 100, y: 200),
                        size: Size(width: 80, height: 44))
        )
    }

    @Test("returns node + workspace + empty candidates when sim and Metro are reachable")
    func happy_path() async throws {
        let sims = MockSimulators()
        let sim = MockSimulator()
        let ax = MockAccessibility()
        let metro = MockMetro()
        let hit = sampleNode()
        let root = URL(fileURLWithPath: "/Users/dev/taskr")
        given(sim).accessibility().willReturn(ax)
        given(ax).describeAll().willReturn(hit)
        given(sims).find(udid: .any).willReturn(sim)
        given(metro).projectRoot().willReturn(root)

        let json = try #require(await Server.triangulateJSONString(
            input: TriangulateInput(udid: "U-1", x: 110, y: 220),
            simulators: sims,
            metro: metro,
            readFile: { _ in #"{"dependencies":{"expo-router":"3.0"}}"# }
        ))

        let probe = try JSONDecoder().decode(TriangulateProbe.self, from: Data(json.utf8))
        #expect(probe.ok == true)
        #expect(probe.node?.role == "AXButton")
        #expect(probe.workspace?.root == "/Users/dev/taskr")
        #expect(probe.workspace?.framework == "expoRouter")
        #expect(probe.candidates.isEmpty)
    }

    @Test("returns ok:true with null workspace when Metro is unreachable")
    func no_metro() async throws {
        let sims = MockSimulators()
        let sim = MockSimulator()
        let ax = MockAccessibility()
        let metro = MockMetro()
        given(sim).accessibility().willReturn(ax)
        given(ax).describeAll().willReturn(sampleNode())
        given(sims).find(udid: .any).willReturn(sim)
        given(metro).projectRoot().willReturn(nil)

        let json = try #require(await Server.triangulateJSONString(
            input: TriangulateInput(udid: "U-1", x: 110, y: 220),
            simulators: sims,
            metro: metro,
            readFile: { _ in nil }
        ))

        let probe = try JSONDecoder().decode(TriangulateProbe.self, from: Data(json.utf8))
        #expect(probe.ok == true)
        #expect(probe.node?.role == "AXButton")
        #expect(probe.workspace == nil)
    }

    @Test("returns nil for an unknown udid")
    func unknown_udid_is_nil() async {
        let sims = MockSimulators()
        let metro = MockMetro()
        given(sims).find(udid: .any).willReturn(nil)

        let json = await Server.triangulateJSONString(
            input: TriangulateInput(udid: "ghost", x: 0, y: 0),
            simulators: sims,
            metro: metro,
            readFile: { _ in nil }
        )
        #expect(json == nil)
    }

    private struct TriangulateProbe: Decodable {
        let ok: Bool
        let node: NodeProbe?
        let workspace: WorkspaceProbe?
        let candidates: [CandidateProbe]
    }
    private struct NodeProbe: Decodable { let role: String }
    private struct WorkspaceProbe: Decodable {
        let root: String
        let framework: String
    }
    private struct CandidateProbe: Decodable {
        let file: String
        let line: Int
    }
}
