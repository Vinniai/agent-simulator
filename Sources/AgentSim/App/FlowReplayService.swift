import Foundation

enum FlowReplayPacing: String, Codable, Sendable {
    case fast
    case realtime
}

enum FlowReplayError: Error, Equatable, CustomStringConvertible {
    case simulatorNotBooted(udid: String)
    case malformedStep(index: Int, reason: String)

    var description: String {
        switch self {
        case .simulatorNotBooted(let udid):
            return "simulator not booted: \(udid)"
        case .malformedStep(let i, let r):
            return "malformed step at index \(i): \(r)"
        }
    }
}

struct FlowReplayResult: Sendable {
    let executed: Int
    let lastOK: Bool
}

enum FlowReplayService {
    static func replay(
        flow: ReviewFlow,
        udid: String,
        pacing: FlowReplayPacing,
        simulators: any Simulators,
        registry: GestureRegistry = .standard
    ) async throws -> FlowReplayResult {
        guard let sim = simulators.find(udid: udid) else {
            throw SimulatorError.notFound(udid: udid)
        }
        guard sim.state == .booted else {
            throw FlowReplayError.simulatorNotBooted(udid: udid)
        }

        let input = sim.input()
        var executed = 0
        var lastOK = true

        for (idx, step) in flow.steps.enumerated() {
            let dict = stepDictionary(step)
            let gesture: any Gesture
            do {
                gesture = try registry.parse(dict)
            } catch let error as GestureError {
                throw FlowReplayError.malformedStep(index: idx, reason: error.message)
            }

            lastOK = gesture.execute(on: input)
            executed += 1
            if !lastOK { break }

            if pacing == .realtime, let delay = stepDelayMs(step), delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            }
        }

        return FlowReplayResult(executed: executed, lastOK: lastOK)
    }

    private static func stepDictionary(_ step: FlowStep) -> [String: Any] {
        var d: [String: Any] = ["type": step.type]
        for (k, v) in step.payload {
            if k == "delayMs" { continue }
            d[k] = jsonValueToAny(v)
        }
        return d
    }

    private static func stepDelayMs(_ step: FlowStep) -> Int? {
        if case .number(let n)? = step.payload["delayMs"] { return Int(n) }
        return nil
    }

    private static func jsonValueToAny(_ v: JSONValue) -> Any {
        switch v {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b):   return b
        case .null:          return NSNull()
        case .array(let a):  return a.map(jsonValueToAny)
        case .object(let o): return o.mapValues(jsonValueToAny)
        }
    }
}
