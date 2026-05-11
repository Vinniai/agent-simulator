import Foundation
import Testing
@testable import Baguette

@Suite("ReviewTaskCodeChange")
struct ReviewTaskCodeChangesTests {

    @Test func `encodes and decodes a full code change record`() throws {
        let change = ReviewTaskCodeChange(
            id: "cc_001",
            taskId: "task_001",
            path: "/abs/Sources/Save/SaveButton.swift",
            summary: "added validation on submit",
            startLine: 42,
            endLine: 58,
            commitSha: "abc123def",
            branch: "main",
            language: "swift",
            diffText: "@@ -42,7 +42,12 @@\n-  func handleSave() {",
            createdAt: Date(timeIntervalSince1970: 1_000_000)
        )

        let data = try JSONEncoder.iso.encode(change)
        let decoded = try JSONDecoder.iso.decode(ReviewTaskCodeChange.self, from: data)

        #expect(decoded == change)
    }

    @Test func `decodes ReviewTask JSON missing codeChanges with empty default`() throws {
        let legacyJSON = """
        {
          "id": "task_1",
          "sessionId": "rev_1",
          "title": "Fix Save",
          "instructions": "Tap Save",
          "status": "open",
          "priority": "normal",
          "createdAt": "1970-01-01T00:00:00Z",
          "updatedAt": "1970-01-01T00:00:00Z",
          "elements": [],
          "events": []
        }
        """
        let data = Data(legacyJSON.utf8)
        let task = try JSONDecoder.iso.decode(ReviewTask.self, from: data)

        #expect(task.codeChanges.isEmpty)
    }

    @Test func `roundtrips a ReviewTask with codeChanges populated`() throws {
        let change = ReviewTaskCodeChange(
            id: "cc_001",
            taskId: "task_1",
            path: "Sources/A.swift",
            summary: nil,
            startLine: 1,
            endLine: 10,
            commitSha: nil,
            branch: nil,
            language: nil,
            diffText: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let task = ReviewTask(
            id: "task_1",
            sessionId: "rev_1",
            bundleId: nil,
            title: "T",
            instructions: "I",
            status: "open",
            priority: "normal",
            assignee: nil,
            contextPath: nil,
            bundleJSONPath: nil,
            bundleMarkdownPath: nil,
            resultSummary: nil,
            verificationSnapshotId: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            claimedAt: nil,
            completedAt: nil,
            elements: [],
            events: [],
            codeChanges: [change]
        )

        let encoded = try JSONEncoder.iso.encode(task)
        let decoded = try JSONDecoder.iso.decode(ReviewTask.self, from: encoded)

        #expect(decoded.codeChanges == [change])
    }

    @Test func `ReviewTaskCodeChangesInput round-trips through JSON`() throws {
        let input = ReviewTaskCodeChangesInput(
            actor: "agent-01",
            changes: [
                ReviewTaskCodeChangeInput(
                    path: "Sources/A.swift",
                    summary: "x",
                    startLine: 1,
                    endLine: 2,
                    commitSha: nil,
                    branch: nil,
                    language: nil,
                    diffText: nil
                )
            ]
        )
        let data = try JSONEncoder.iso.encode(input)
        let decoded = try JSONDecoder.iso.decode(ReviewTaskCodeChangesInput.self, from: data)

        #expect(decoded == input)
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

private extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
