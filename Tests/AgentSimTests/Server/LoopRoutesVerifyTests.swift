import Testing
import Foundation
@testable import AgentSim

/// `LoopRoutes` is the fork-only home (ADR-0001) for the Agentic Feedback
/// Loop's HTTP/CLI surface, kept out of the upstream-tracking `Server`
/// route table. Its first occupant is criteria verification: by default it
/// resolves the task's verification snapshot, reads that snapshot's AX
/// artifact (the `axPath` file), and runs `VerifyTask` against it — no
/// simulator, fully reproducible. These tests drive the snapshot path with
/// real temp stores; the live `describe-ui` path is integration-only.
@Suite("LoopRoutes verify-criteria (snapshot)")
struct LoopRoutesVerifyTests {

    private func reviewStore() -> FileReviewStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-sim-loop-reviews-\(UUID().uuidString)")
        return FileReviewStore(root: dir)
    }
    private func taskStore() -> SQLiteReviewTaskStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-sim-loop-tasks-\(UUID().uuidString)")
        return SQLiteReviewTaskStore(url: dir.appendingPathComponent("tasks.sqlite"))
    }
    private func frame() -> Rect {
        Rect(origin: Point(x: 0, y: 0), size: Size(width: 10, height: 10))
    }
    private func tree() -> AXNode {
        AXNode(role: "AXWindow", label: "New Task", frame: frame(),
               children: [AXNode(role: "AXButton", label: "Save",
                                 identifier: "save-btn", frame: frame(), enabled: true)])
    }

    /// Create a review session holding one snapshot whose AX artifact is
    /// `tree.json`, and a task pointed at it carrying `criteria`.
    private func setup(
        criteria: [AcceptanceCriterion],
        artifact: Data? = nil,
        snapshotId: String? = "snap-1",
        reviews: FileReviewStore,
        tasks: SQLiteReviewTaskStore
    ) throws -> String {
        var session = try reviews.createSession(name: "verify")
        if let snapshotId {
            try reviews.writeArtifact(
                sessionId: session.id,
                relativePath: "ax/\(snapshotId).json",
                data: artifact ?? Data(tree().json.utf8))
            session.snapshots = [ReviewScreenSnapshot(
                id: snapshotId, sessionId: session.id, udid: "U", timestamp: Date(),
                screenshotPath: "shots/\(snapshotId).jpg", axPath: "ax/\(snapshotId).json",
                screenFingerprint: "fp", markers: [], elements: nil)]
            try reviews.saveSession(session)
        }
        let now = Date()
        _ = try tasks.createTask(ReviewTask(
            id: "task-1", sessionId: session.id, bundleId: nil, title: "T",
            instructions: "I", status: "readyForVerify", priority: "normal",
            assignee: nil, contextPath: nil, bundleJSONPath: nil,
            bundleMarkdownPath: nil, resultSummary: nil,
            verificationSnapshotId: snapshotId, createdAt: now, updatedAt: now,
            claimedAt: nil, completedAt: nil, elements: [], events: [],
            codeChanges: [], criteria: criteria, verdicts: []))
        return "task-1"
    }

    @Test("verifies a task against its captured snapshot artifact")
    func verifiesFromSnapshot() throws {
        let reviews = reviewStore(); let tasks = taskStore()
        let id = try setup(criteria: [
            AcceptanceCriterion(description: "Save present",
                                selector: ElementSelector(identifier: "save-btn"),
                                expect: .exists),
        ], reviews: reviews, tasks: tasks)

        let result = try LoopRoutes.verifyFromSnapshot(
            taskId: id, taskStore: tasks, reviewStore: reviews)
        #expect(result.status == "verified")
        #expect(result.verdicts.count == 1)
        #expect(try tasks.loadTask(id: id).status == "verified")
    }

    @Test("a failing criterion against the snapshot sends the task back to open")
    func failsFromSnapshot() throws {
        let reviews = reviewStore(); let tasks = taskStore()
        let id = try setup(criteria: [
            AcceptanceCriterion(description: "Cancel present",
                                selector: ElementSelector(label: "Cancel"),
                                expect: .exists),
        ], reviews: reviews, tasks: tasks)

        let result = try LoopRoutes.verifyFromSnapshot(
            taskId: id, taskStore: tasks, reviewStore: reviews)
        #expect(result.status == "open")
        #expect(result.verdicts.first?.outcome == .fail)
    }

    @Test("a task with no verification snapshot is rejected, not silently passed")
    func noSnapshotThrows() throws {
        let reviews = reviewStore(); let tasks = taskStore()
        let id = try setup(criteria: [
            AcceptanceCriterion(description: "x",
                                selector: ElementSelector(identifier: "save-btn"),
                                expect: .exists),
        ], snapshotId: nil, reviews: reviews, tasks: tasks)

        #expect(throws: (any Error).self) {
            _ = try LoopRoutes.verifyFromSnapshot(
                taskId: id, taskStore: tasks, reviewStore: reviews)
        }
    }

    @Test("a corrupt AX artifact is rejected rather than read as an empty tree")
    func corruptArtifactThrows() throws {
        let reviews = reviewStore(); let tasks = taskStore()
        let id = try setup(criteria: [
            AcceptanceCriterion(description: "x",
                                selector: ElementSelector(identifier: "save-btn"),
                                expect: .exists),
        ], artifact: Data("not a tree".utf8), reviews: reviews, tasks: tasks)

        #expect(throws: (any Error).self) {
            _ = try LoopRoutes.verifyFromSnapshot(
                taskId: id, taskStore: tasks, reviewStore: reviews)
        }
    }
}
