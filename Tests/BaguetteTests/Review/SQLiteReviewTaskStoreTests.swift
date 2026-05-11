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

    @Test("appendCodeChanges persists, hydrates, and emits a code_changes event")
    func appendCodeChangesRoundtrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baguette-task-tests-\(UUID().uuidString)")
        let store = SQLiteReviewTaskStore(url: dir.appendingPathComponent("tasks.sqlite"))
        let now = Date()
        let task = ReviewTask(
            id: "task-cc",
            sessionId: "review-cc",
            bundleId: nil,
            title: "Fix Save",
            instructions: "Tap Save and confirm row appears",
            status: "open",
            priority: "normal",
            assignee: nil,
            contextPath: nil,
            bundleJSONPath: nil,
            bundleMarkdownPath: nil,
            resultSummary: nil,
            verificationSnapshotId: nil,
            createdAt: now,
            updatedAt: now,
            claimedAt: nil,
            completedAt: nil,
            elements: [],
            events: []
        )
        _ = try store.createTask(task)

        let result = try store.appendCodeChanges(
            taskId: "task-cc",
            input: ReviewTaskCodeChangesInput(
                actor: "agent-a",
                changes: [
                    ReviewTaskCodeChangeInput(
                        path: "Sources/Save/SaveButton.swift",
                        summary: "added validation on submit",
                        startLine: 42,
                        endLine: 58,
                        commitSha: "abc123",
                        branch: "main",
                        language: "swift",
                        diffText: "@@ -42,7 +42,12 @@"
                    ),
                    ReviewTaskCodeChangeInput(
                        path: "Sources/Save/SaveStore.swift",
                        summary: "handle save error",
                        startLine: 12,
                        endLine: 21,
                        commitSha: "abc123",
                        branch: "main",
                        language: "swift",
                        diffText: nil
                    )
                ]
            )
        )

        #expect(result.codeChanges.count == 2)
        #expect(result.codeChanges[0].path == "Sources/Save/SaveButton.swift")
        #expect(result.codeChanges[0].startLine == 42)
        #expect(result.codeChanges[0].diffText == "@@ -42,7 +42,12 @@")
        #expect(result.codeChanges[1].diffText == nil)
        #expect(result.events.contains { $0.type == "code_changes" && $0.actor == "agent-a" })

        let reloaded = try store.loadTask(id: "task-cc")
        #expect(reloaded.codeChanges.count == 2)
        #expect(reloaded.codeChanges.map(\.path) == [
            "Sources/Save/SaveButton.swift",
            "Sources/Save/SaveStore.swift",
        ])
    }

    @Test("bulkCreateTasks creates every supplied task with shared defaults")
    func bulkCreateAllSucceed() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baguette-task-tests-\(UUID().uuidString)")
        let store = SQLiteReviewTaskStore(url: dir.appendingPathComponent("tasks.sqlite"))

        let result = try store.bulkCreateTasks(
            input: ReviewTaskBulkCreateInput(
                sessionId: "review-bulk",
                defaults: ReviewTaskBulkDefaults(
                    priority: "high",
                    assignee: "agent-import",
                    instructions: nil,
                    title: nil
                ),
                tasks: [
                    ReviewTaskBulkItem(
                        title: "Fix /home",
                        instructions: "Re-align hero card",
                        elements: [
                            ReviewTaskElementInput(
                                snapshotId: "snap-1", axNodePath: "/", commentText: "card off-grid"
                            )
                        ]
                    ),
                    ReviewTaskBulkItem(
                        title: "Fix /search",
                        instructions: "Move filter button right",
                        elements: [
                            ReviewTaskElementInput(
                                snapshotId: "snap-2", axNodePath: "/", commentText: nil
                            )
                        ]
                    ),
                ]
            )
        )

        #expect(result.errors.isEmpty)
        #expect(result.created.count == 2)
        #expect(result.created.map(\.title) == ["Fix /home", "Fix /search"])
        #expect(result.created.map(\.priority) == ["high", "high"])
        #expect(result.created.map(\.assignee) == ["agent-import", "agent-import"])
        #expect(result.created.map { $0.elements.count } == [1, 1])
        #expect(result.created[0].elements[0].snapshotId == "snap-1")
        #expect(result.created[0].events.contains { $0.type == "created" })

        // Both tasks should be findable.
        let listed = try store.listTasks(sessionId: "review-bulk", status: nil)
        #expect(Set(listed.map(\.title)) == ["Fix /home", "Fix /search"])
    }

    @Test("bulkCreateTasks records per-item errors without aborting the batch")
    func bulkCreatePartialFailure() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baguette-task-tests-\(UUID().uuidString)")
        let store = SQLiteReviewTaskStore(url: dir.appendingPathComponent("tasks.sqlite"))

        let result = try store.bulkCreateTasks(
            input: ReviewTaskBulkCreateInput(
                sessionId: "review-bulk-2",
                defaults: nil,
                tasks: [
                    ReviewTaskBulkItem(title: "Good", instructions: "ok", elements: []),
                    ReviewTaskBulkItem(title: "", instructions: "", elements: []),   // blank title — rejected
                    ReviewTaskBulkItem(title: "Also good", instructions: "ok", elements: []),
                ]
            )
        )

        #expect(result.created.count == 2)
        #expect(result.errors.count == 1)
        #expect(result.errors[0].index == 1)
        #expect(result.created.map(\.title) == ["Good", "Also good"])
    }

    @Test("bulkCreateTasks per-task title beats defaults; defaults beat fallback")
    func bulkCreateDefaultsResolution() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baguette-task-tests-\(UUID().uuidString)")
        let store = SQLiteReviewTaskStore(url: dir.appendingPathComponent("tasks.sqlite"))

        let result = try store.bulkCreateTasks(
            input: ReviewTaskBulkCreateInput(
                sessionId: "review-bulk-3",
                defaults: ReviewTaskBulkDefaults(
                    priority: "low",
                    assignee: "from-default",
                    instructions: "default-instructions",
                    title: "Default Title"
                ),
                tasks: [
                    ReviewTaskBulkItem(title: "Explicit", instructions: nil, elements: []),
                    ReviewTaskBulkItem(title: nil, instructions: "Explicit instructions", elements: []),
                ]
            )
        )

        #expect(result.errors.isEmpty)
        // Explicit title beats default
        #expect(result.created[0].title == "Explicit")
        // No title → falls through to default
        #expect(result.created[1].title == "Default Title")
        // No instructions on first → falls through to default
        #expect(result.created[0].instructions == "default-instructions")
        // Explicit instructions on second
        #expect(result.created[1].instructions == "Explicit instructions")
        // Both inherit default priority + assignee
        #expect(result.created.map(\.priority) == ["low", "low"])
        #expect(result.created.map(\.assignee) == ["from-default", "from-default"])
    }
}
