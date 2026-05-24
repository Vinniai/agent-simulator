import Testing
import Foundation
@testable import AgentSim

/// A Review Task carries the Acceptance Criteria it must satisfy (authored
/// at creation, like `elements`) and the Verdicts produced when it is
/// verified (written by the verify use-case, like `events`). Both must
/// survive a JSON round-trip, and tasks created before this feature — whose
/// JSON has neither field — must decode to empty arrays so old queues load.
@Suite("ReviewTask criteria/verdicts")
struct ReviewTaskCriteriaTests {

    private func task(
        criteria: [AcceptanceCriterion],
        verdicts: [Verdict]
    ) -> ReviewTask {
        ReviewTask(
            id: "task-1", sessionId: "rev-1", bundleId: nil,
            title: "T", instructions: "I", status: "open", priority: "normal",
            assignee: nil, contextPath: nil, bundleJSONPath: nil,
            bundleMarkdownPath: nil, resultSummary: nil,
            verificationSnapshotId: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            claimedAt: nil, completedAt: nil,
            elements: [], events: [], codeChanges: [],
            criteria: criteria, verdicts: verdicts)
    }

    @Test("round-trips populated criteria and verdicts through JSON")
    func roundtripPopulated() throws {
        let c = AcceptanceCriterion(
            description: "Save enabled",
            selector: ElementSelector(identifier: "save-btn"),
            expect: .enabled)
        let v = Verdict(criterion: c, outcome: .pass, reason: nil)
        let original = task(criteria: [c], verdicts: [v])

        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ReviewTask.self, from: try encoder.encode(original))

        #expect(decoded.criteria == [c])
        #expect(decoded.verdicts == [v])
    }

    @Test("legacy JSON without criteria/verdicts decodes to empty arrays")
    func legacyDecodesEmpty() throws {
        let legacyJSON = """
        {
          "id": "task_1", "sessionId": "rev_1", "title": "Fix Save",
          "instructions": "Tap Save", "status": "open", "priority": "normal",
          "createdAt": "1970-01-01T00:00:00Z", "updatedAt": "1970-01-01T00:00:00Z",
          "elements": [], "events": []
        }
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ReviewTask.self, from: Data(legacyJSON.utf8))
        #expect(decoded.criteria.isEmpty)
        #expect(decoded.verdicts.isEmpty)
    }
}
