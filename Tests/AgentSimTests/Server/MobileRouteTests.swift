import Testing
import Foundation
@testable import AgentSim

/// The mobile entry point. `/m/<udid>` is the thumb-friendly single-sim
/// view used while away from the desk; bare `/m` stays the device-farm
/// dashboard. Both `/m/<udid>` and `/simulators/<udid>` serve the same
/// `sim.html` shell — the client JS routes the inner focus view from the
/// URL path. These tests pin the path → static-asset mapping so the new
/// mobile route can't silently regress the farm alias or the desktop
/// deep-link.
@Suite("Server mobile route")
struct MobileRouteTests {

    @Test func `m with a udid serves the single-sim shell`() {
        #expect(Server.shellAsset(forPath: "/m/UDID-1") == "sim.html")
    }

    @Test func `m with an encoded udid still serves the single-sim shell`() {
        #expect(Server.shellAsset(forPath: "/m/ABC-123-DEF") == "sim.html")
    }

    @Test func `bare m stays the device-farm dashboard`() {
        #expect(Server.shellAsset(forPath: "/m") == "farm/farm.html")
        #expect(Server.shellAsset(forPath: "/m/") == "farm/farm.html")
    }

    @Test func `simulators deep-link still serves the shell (regression)`() {
        #expect(Server.shellAsset(forPath: "/simulators/UDID-1") == "sim.html")
        #expect(Server.shellAsset(forPath: "/simulators") == "sim.html")
    }

    @Test func `farm still serves the dashboard (regression)`() {
        #expect(Server.shellAsset(forPath: "/farm") == "farm/farm.html")
    }
}
