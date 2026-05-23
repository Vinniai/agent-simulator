import Testing
import Foundation
import Mockable
@testable import AgentSim

/// Discovery composes a `Metro` collaborator (the dev server) with a
/// file reader to produce a `Workspace`. Pinning the orchestration
/// here means callers can test against `MockMetro` without standing
/// up a real Metro process, and the irreducible HTTP / lsof I/O
/// stays isolated in `HostMetro`.
@Suite("Workspace.discover(metro:readFile:)")
struct MetroDiscoveryTests {

    @Test("returns nil when Metro is unreachable")
    func unreachable_yields_nil() async {
        let metro = MockMetro()
        given(metro).projectRoot().willReturn(nil)
        let ws = await Workspace.discover(metro: metro, readFile: { _ in nil })
        #expect(ws == nil)
    }

    @Test("returns Workspace with .expoRouter when package.json declares it")
    func expo_router_detected_from_pkg() async {
        let root = URL(fileURLWithPath: "/Users/dev/taskr")
        let metro = MockMetro()
        given(metro).projectRoot().willReturn(root)
        let reader: (URL) -> String? = { url in
            guard url.path.hasSuffix("package.json") else { return nil }
            return #"{"dependencies":{"expo-router":"3.4.0"}}"#
        }
        let ws = await Workspace.discover(metro: metro, readFile: reader)
        #expect(ws == Workspace(root: root, framework: .expoRouter))
    }

    @Test("returns Workspace with .unknown when package.json is absent")
    func missing_pkg_falls_back_to_unknown() async {
        let root = URL(fileURLWithPath: "/Users/dev/legacy-rn")
        let metro = MockMetro()
        given(metro).projectRoot().willReturn(root)
        let ws = await Workspace.discover(metro: metro, readFile: { _ in nil })
        #expect(ws == Workspace(root: root, framework: .unknown))
    }
}
