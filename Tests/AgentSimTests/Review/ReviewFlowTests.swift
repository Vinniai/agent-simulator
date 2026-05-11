import Testing
import Foundation
@testable import AgentSim

@Suite("ReviewFlow")
struct ReviewFlowTests {

    @Test func `flow round-trips through JSON with mixed step shapes`() throws {
        let flow = ReviewFlow(
            id: "flow-1",
            sessionId: "review-abc",
            name: "Sign in then tap save",
            steps: [
                FlowStep(type: "tap", payload: [
                    "x": .number(120),
                    "y": .number(340),
                    "width": .number(402),
                    "height": .number(874),
                    "delayMs": .number(0),
                ]),
                FlowStep(type: "type", payload: [
                    "text": .string("hello@example.com"),
                    "delayMs": .number(120),
                ]),
                FlowStep(type: "button", payload: [
                    "button": .string("home"),
                    "delayMs": .number(0),
                ]),
            ],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            createdBy: "agent-browser"
        )

        let data = try JSONEncoder().encode(flow)
        let decoded = try JSONDecoder().decode(ReviewFlow.self, from: data)

        #expect(decoded.id == flow.id)
        #expect(decoded.sessionId == flow.sessionId)
        #expect(decoded.name == flow.name)
        #expect(decoded.steps.count == 3)
        #expect(decoded.steps[0].type == "tap")
        if case .number(let x)? = decoded.steps[0].payload["x"] {
            #expect(x == 120)
        } else { Issue.record("tap payload x missing or not a number") }
        if case .string(let text)? = decoded.steps[1].payload["text"] {
            #expect(text == "hello@example.com")
        } else { Issue.record("type payload text missing or not a string") }
        #expect(decoded.createdBy == "agent-browser")
    }

    @Test func `step order is preserved across encode-decode`() throws {
        let labels = ["a", "b", "c", "d", "e", "f"]
        let steps = labels.map { FlowStep(type: "tag", payload: ["label": .string($0)]) }
        let flow = ReviewFlow(
            id: "flow-order",
            sessionId: "review-x",
            name: "Order test",
            steps: steps,
            createdAt: Date(),
            createdBy: nil
        )
        let data = try JSONEncoder().encode(flow)
        let decoded = try JSONDecoder().decode(ReviewFlow.self, from: data)

        let decodedLabels = decoded.steps.compactMap { step -> String? in
            if case .string(let s)? = step.payload["label"] { return s }
            return nil
        }
        #expect(decodedLabels == labels)
    }

    @Test func `empty steps is allowed but recorded as zero`() throws {
        let flow = ReviewFlow(
            id: "flow-empty",
            sessionId: "review-x",
            name: "Empty",
            steps: [],
            createdAt: Date(),
            createdBy: nil
        )
        let data = try JSONEncoder().encode(flow)
        let decoded = try JSONDecoder().decode(ReviewFlow.self, from: data)
        #expect(decoded.steps.isEmpty)
    }

    @Test func `JSONValue handles nested objects + arrays in payloads`() throws {
        let payload: [String: JSONValue] = [
            "type": .string("touch2-down"),
            "p1": .object([
                "x": .number(100),
                "y": .number(200),
            ]),
            "p2": .object([
                "x": .number(300),
                "y": .number(200),
            ]),
            "tags": .array([.string("pinch"), .string("multi")]),
            "nullable": .null,
        ]
        let step = FlowStep(type: "touch2-down", payload: payload)
        let data = try JSONEncoder().encode(step)
        let decoded = try JSONDecoder().decode(FlowStep.self, from: data)

        if case .object(let p1)? = decoded.payload["p1"],
           case .number(let x)? = p1["x"] {
            #expect(x == 100)
        } else { Issue.record("nested p1.x not preserved") }
        if case .array(let tags)? = decoded.payload["tags"],
           case .string(let first)? = tags.first {
            #expect(first == "pinch")
        } else { Issue.record("tags array not preserved") }
        if case .null? = decoded.payload["nullable"] {
            // ok
        } else { Issue.record("null value not preserved") }
    }
}
