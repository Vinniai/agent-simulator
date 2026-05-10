import Foundation
import Testing
@testable import Baguette

@Suite("SQLite review task store")
struct SQLiteReviewTaskStoreTests {
    @Test("creates, lists, claims, updates, and verifies tasks")
    func taskLifecycle() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baguette-task-tests-\(UUID().uuidString)")
        let store = SQLiteReviewTaskStore(url: dir.appendingPathComponent("tasks.sqlite"))
        let now = Date()
        let task = ReviewTask(
            id: "task-1",
            sessionId: "review-1",
            bundleId: "bundle-1",
            title: "Make buttons red",
            instructions: "Change selected buttons to red.",
            status: "open",
            priority: "normal",
            assignee: nil,
            contextPath: "tasks/task-1/context.md",
            bundleJSONPath: "bundles/bundle-1/bundle.json",
            bundleMarkdownPath: "bundles/bundle-1/brief.md",
            resultSummary: nil,
            verificationSnapshotId: nil,
            createdAt: now,
            updatedAt: now,
            claimedAt: nil,
            completedAt: nil,
            elements: [
                ReviewTaskElement(
                    id: "taskel-1",
                    taskId: "task-1",
                    snapshotId: "snap-1",
                    axNodePath: "/children/0",
                    role: "AXButton",
                    label: "Continue",
                    frame: Rect(
                        origin: Point(x: 10, y: 20),
                        size: Size(width: 100, height: 44)
                    ),
                    commentText: "Make this red"
                )
            ],
            events: [
                ReviewTaskEvent(
                    id: "event-1",
                    taskId: "task-1",
                    type: "created",
                    actor: nil,
                    message: "Created",
                    metadataJSON: nil,
                    createdAt: now
                )
            ]
        )

        let created = try store.createTask(task)
        #expect(created.elements.count == 1)
        #expect(try store.listTasks(sessionId: "review-1", status: "open").map(\.id) == ["task-1"])

        let claimed = try #require(try store.claimNext(agentId: "agent-a"))
        #expect(claimed.id == "task-1")
        #expect(claimed.status == "claimed")
        #expect(claimed.assignee == "agent-a")

        let updated = try store.updateTask(
            id: "task-1",
            input: ReviewTaskUpdateInput(
                status: "readyForVerify",
                assignee: nil,
                resultSummary: "Changed button color.",
                verificationSnapshotId: "snap-2",
                notes: "Ready",
                actor: "agent-a"
            )
        )
        #expect(updated.status == "readyForVerify")
        #expect(updated.resultSummary == "Changed button color.")

        let verified = try store.addVerification(
            taskId: "task-1",
            verification: ReviewTaskVerification(
                id: "verify-1",
                taskId: "task-1",
                beforeSnapshotIds: ["snap-1"],
                afterSnapshotId: "snap-2",
                status: "passed",
                notes: "Visual check passed",
                createdAt: Date()
            )
        )
        #expect(verified.events.contains { $0.type == "verification:passed" })
    }
}
