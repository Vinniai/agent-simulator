import Testing
import Foundation
import Mockable
@testable import AgentSim

/// `SimulatorStartupPlan.decide` is the policy serve runs before
/// binding: it guarantees the picker has a booted simulator to attach
/// to without ever disturbing one the operator already has up.
///
/// The rule, in domain terms:
///  - something already coming up (booted *or* booting) → leave it be;
///  - otherwise a simulator with the auto-boot name already in the set
///    → boot that one rather than spawning a duplicate;
///  - otherwise → create a fresh auto-boot simulator and boot it.
@Suite("SimulatorStartupPlan")
struct SimulatorStartupPlanTests {

    @Test func `a booted simulator means there is nothing to provision`() {
        let plan = SimulatorStartupPlan.decide(
            all: [sim("U1", "iPhone 17 Pro", .booted)],
            desiredName: "agent-sim"
        )
        #expect(plan == .useRunning)
    }

    @Test func `a simulator already booting is left to come up`() {
        let plan = SimulatorStartupPlan.decide(
            all: [sim("U1", "iPhone 17 Pro", .booting)],
            desiredName: "agent-sim"
        )
        #expect(plan == .useRunning)
    }

    @Test func `an existing agent-sim is booted rather than duplicated`() {
        let plan = SimulatorStartupPlan.decide(
            all: [
                sim("U1", "iPhone 17 Pro", .shutdown),
                sim("U2", "agent-sim",     .shutdown),
            ],
            desiredName: "agent-sim"
        )
        #expect(plan == .bootExisting(udid: "U2"))
    }

    @Test func `the agent-sim match is case-insensitive`() {
        let plan = SimulatorStartupPlan.decide(
            all: [sim("U2", "Agent-Sim", .shutdown)],
            desiredName: "agent-sim"
        )
        #expect(plan == .bootExisting(udid: "U2"))
    }

    @Test func `nothing booted and no agent-sim means create one`() {
        let plan = SimulatorStartupPlan.decide(
            all: [sim("U1", "iPhone 17 Pro", .shutdown)],
            desiredName: "agent-sim"
        )
        #expect(plan == .createAndBoot(name: "agent-sim"))
    }

    @Test func `an empty fleet means create one`() {
        let plan = SimulatorStartupPlan.decide(all: [], desiredName: "agent-sim")
        #expect(plan == .createAndBoot(name: "agent-sim"))
    }

    // MARK: - helpers

    private func sim(_ udid: String, _ name: String, _ state: SimulatorState) -> any Simulator {
        let s = MockSimulator()
        given(s).udid.willReturn(udid)
        given(s).name.willReturn(name)
        given(s).state.willReturn(state)
        return s
    }
}
