import Testing
import Foundation
@testable import AgentSim

/// Acceptance Criteria are authored by an agent as JSON at task-creation
/// time and read back from storage, so the value types must encode to a
/// stable, human-authorable shape. `ExpectedState` carries associated values
/// (`textEquals`/`textContains`), so it gets a `kind`-tagged object —
/// `{"kind":"textEquals","text":"Done"}` — rather than Swift's default
/// nested `{"textEquals":{"_0":"Done"}}`.
@Suite("AcceptanceCriterion Codable")
struct AcceptanceCriterionCodableTests {

    private func object(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("a text expectation encodes as a kind-tagged object with its text")
    func textExpectedStateShape() throws {
        let obj = try object(ExpectedState.textEquals("Done"))
        #expect(obj["kind"] as? String == "textEquals")
        #expect(obj["text"] as? String == "Done")
    }

    @Test("a bare expectation encodes with only its kind")
    func bareExpectedStateShape() throws {
        let obj = try object(ExpectedState.exists)
        #expect(obj["kind"] as? String == "exists")
        #expect(obj["text"] == nil)
    }

    @Test("every expectation case round-trips through JSON")
    func expectationRoundtrip() throws {
        let cases: [ExpectedState] = [
            .exists, .absent, .enabled, .disabled,
            .textEquals("hello"), .textContains("ell"),
        ]
        for e in cases {
            let data = try JSONEncoder().encode(e)
            let decoded = try JSONDecoder().decode(ExpectedState.self, from: data)
            #expect(decoded == e)
        }
    }

    @Test("a criterion round-trips selector + expectation + description")
    func criterionRoundtrip() throws {
        let c = AcceptanceCriterion(
            description: "Save button is enabled",
            selector: ElementSelector(identifier: "save-btn", role: "AXButton"),
            expect: .enabled)
        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(AcceptanceCriterion.self, from: data)
        #expect(decoded == c)
    }

    @Test("a verdict round-trips with its outcome as a string")
    func verdictRoundtrip() throws {
        let c = AcceptanceCriterion(
            description: "no error shown",
            selector: ElementSelector(label: "Name required"),
            expect: .absent)
        let v = Verdict(criterion: c, outcome: .fail, reason: "found 1 match")
        let obj = try object(v)
        #expect(obj["outcome"] as? String == "fail")

        let data = try JSONEncoder().encode(v)
        let decoded = try JSONDecoder().decode(Verdict.self, from: data)
        #expect(decoded == v)
    }
}
