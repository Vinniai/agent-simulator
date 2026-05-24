import Testing
import Foundation
import Mockable
@testable import AgentSim

@Suite("FlowReplayService")
struct FlowReplayServiceTests {

    @Test func `executes every step in order against the booted sim's input`() async throws {
        let input = MockInput()
        given(input).tap(at: .any, size: .any, duration: .any).willReturn(true)
        given(input).button(.any, duration: .any).willReturn(true)

        let sim = makeSim(udid: "U1", state: .booted, input: input)
        let host = MockSimulators()
        given(host).find(udid: .value("U1")).willReturn(sim)

        let flow = ReviewFlow(
            id: "flow-1",
            sessionId: "review-x",
            name: "Test",
            steps: [
                FlowStep(type: "tap", payload: [
                    "x": .number(10), "y": .number(20),
                    "width": .number(100), "height": .number(200),
                ]),
                FlowStep(type: "button", payload: ["button": .string("home")]),
            ],
            createdAt: Date(),
            createdBy: nil
        )

        let result = try await FlowReplayService.replay(
            flow: flow, udid: "U1", pacing: .fast, simulators: host
        )

        #expect(result.executed == 2)
        #expect(result.lastOK == true)
        verify(input).tap(at: .any, size: .any, duration: .any).called(1)
        verify(input).button(.any, duration: .any).called(1)
    }

    @Test func `stops at first failing step and reports lastOK = false`() async throws {
        let input = MockInput()
        given(input).tap(at: .any, size: .any, duration: .any).willReturn(false)
        let sim = makeSim(udid: "U1", state: .booted, input: input)
        let host = MockSimulators()
        given(host).find(udid: .value("U1")).willReturn(sim)

        let flow = ReviewFlow(
            id: "flow-2", sessionId: "review-x", name: "Fail-fast",
            steps: [
                FlowStep(type: "tap", payload: [
                    "x": .number(1), "y": .number(1),
                    "width": .number(1), "height": .number(1),
                ]),
                FlowStep(type: "tap", payload: [
                    "x": .number(2), "y": .number(2),
                    "width": .number(1), "height": .number(1),
                ]),
            ],
            createdAt: Date(), createdBy: nil
        )

        let result = try await FlowReplayService.replay(
            flow: flow, udid: "U1", pacing: .fast, simulators: host
        )

        #expect(result.executed == 1)
        #expect(result.lastOK == false)
    }

    @Test func `throws notFound when the udid is unknown`() async throws {
        let host = MockSimulators()
        given(host).find(udid: .any).willReturn(nil)
        let flow = ReviewFlow(
            id: "flow-3", sessionId: "review-x", name: "", steps: [],
            createdAt: Date(), createdBy: nil
        )

        await #expect(throws: SimulatorError.self) {
            _ = try await FlowReplayService.replay(
                flow: flow, udid: "ghost", pacing: .fast, simulators: host
            )
        }
    }

    @Test func `throws when target simulator is not booted`() async throws {
        let input = MockInput()
        let sim = makeSim(udid: "U1", state: .shutdown, input: input)
        let host = MockSimulators()
        given(host).find(udid: .value("U1")).willReturn(sim)

        let flow = ReviewFlow(
            id: "flow-4", sessionId: "review-x", name: "", steps: [],
            createdAt: Date(), createdBy: nil
        )

        await #expect(throws: FlowReplayError.self) {
            _ = try await FlowReplayService.replay(
                flow: flow, udid: "U1", pacing: .fast, simulators: host
            )
        }
    }

    @Test func `surfaces malformed step as FlowReplayError-malformedStep`() async throws {
        let input = MockInput()
        let sim = makeSim(udid: "U1", state: .booted, input: input)
        let host = MockSimulators()
        given(host).find(udid: .value("U1")).willReturn(sim)

        let flow = ReviewFlow(
            id: "flow-5", sessionId: "review-x", name: "",
            steps: [FlowStep(type: "blargh", payload: [:])],
            createdAt: Date(), createdBy: nil
        )

        await #expect(throws: FlowReplayError.self) {
            _ = try await FlowReplayService.replay(
                flow: flow, udid: "U1", pacing: .fast, simulators: host
            )
        }
    }

    private func makeSim(
        udid: String, state: SimulatorState, input: any Input
    ) -> any Simulator {
        let s = MockSimulator()
        given(s).udid.willReturn(udid)
        given(s).state.willReturn(state)
        given(s).input().willReturn(input)
        return s
    }
}
