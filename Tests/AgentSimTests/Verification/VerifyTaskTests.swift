import Testing
import Foundation
@testable import AgentSim

/// `VerifyTask` is the authoritative verify use-case (ADR-0002): given a
/// task's id and an AX tree, it runs the task's acceptance criteria through
/// `CriteriaCheck`, records the verdicts, and drives status — all criteria
/// passing marks the task `verified`, any fail/ambiguous sends it back to
/// `open`. The tree is supplied by the caller (a captured snapshot or live
/// `describe-ui`), so this is exercised state-based against a real store
/// with a fixture tree, no simulator.
@Suite("VerifyTask")
struct VerifyTaskTests {

    private func store() -> SQLiteReviewTaskStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-simulator-verify-tests-\(UUID().uuidString)")
        return SQLiteReviewTaskStore(url: dir.appendingPathComponent("tasks.sqlite"))
    }

    private func frame() -> Rect {
        Rect(origin: Point(x: 0, y: 0), size: Size(width: 10, height: 10))
    }

    /// A screen with an enabled Save button carrying a testID.
    private func tree() -> AXNode {
        AXNode(
            role: "AXWindow", label: "New Task", frame: frame(),
            children: [
                AXNode(role: "AXButton", label: "Save", identifier: "save-btn",
                       frame: frame(), enabled: true)
            ])
    }

    private func task(
        id: String,
        in store: SQLiteReviewTaskStore,
        criteria: [AcceptanceCriterion]
    ) throws -> ReviewTask {
        let now = Date()
        return try store.createTask(ReviewTask(
            id: id, sessionId: "rev-v", bundleId: nil, title: "T",
            instructions: "I", status: "readyForVerify", priority: "normal",
            assignee: nil, contextPath: nil, bundleJSONPath: nil,
            bundleMarkdownPath: nil, resultSummary: nil,
            verificationSnapshotId: nil, createdAt: now, updatedAt: now,
            claimedAt: nil, completedAt: nil, elements: [], events: [],
            codeChanges: [], criteria: criteria, verdicts: []))
    }

    @Test("all criteria passing marks the task verified and persists verdicts")
    func allPassVerifies() throws {
        let s = store()
        _ = try task(id: "t-pass", in: s, criteria: [
            AcceptanceCriterion(description: "Save exists",
                                selector: ElementSelector(identifier: "save-btn"),
                                expect: .exists),
            AcceptanceCriterion(description: "Save enabled",
                                selector: ElementSelector(identifier: "save-btn"),
                                expect: .enabled),
        ])

        let result = try VerifyTask.run(store: s, taskId: "t-pass", tree: tree())
        #expect(result.status == "verified")
        #expect(result.verdicts.count == 2)
        #expect(result.verdicts.allSatisfy { $0.outcome == .pass })

        let reloaded = try s.loadTask(id: "t-pass")
        #expect(reloaded.status == "verified")
        #expect(reloaded.verdicts.count == 2)
    }

    @Test("a failing criterion sends the task back to open with a reason")
    func failReopens() throws {
        let s = store()
        _ = try task(id: "t-fail", in: s, criteria: [
            AcceptanceCriterion(description: "Save exists",
                                selector: ElementSelector(identifier: "save-btn"),
                                expect: .exists),                     // pass
            AcceptanceCriterion(description: "Cancel exists",
                                selector: ElementSelector(label: "Cancel"),
                                expect: .exists),                     // fail
        ])

        let result = try VerifyTask.run(store: s, taskId: "t-fail", tree: tree())
        #expect(result.status == "open")
        #expect(result.verdicts.map(\.outcome) == [.pass, .fail])
        #expect(result.verdicts[1].reason != nil)
    }

    @Test("an ambiguous criterion also keeps the task open")
    func ambiguousReopens() throws {
        let s = store()
        // Two "Save"-labelled nodes would be ambiguous; here a single node,
        // but asking enabled on a label that also hits the window is fine —
        // use a multi-match by label across the window+button.
        _ = try task(id: "t-amb", in: s, criteria: [
            AcceptanceCriterion(description: "the Save thing is enabled",
                                selector: ElementSelector(label: "Save"),
                                expect: .enabled),
        ])
        // tree() has exactly one "Save" — make it ambiguous by adding a twin.
        let twinned = AXNode(
            role: "AXWindow", label: "New Task", frame: frame(),
            children: [
                AXNode(role: "AXButton", label: "Save", identifier: "save-btn",
                       frame: frame(), enabled: true),
                AXNode(role: "AXStaticText", label: "Save", frame: frame()),
            ])
        let result = try VerifyTask.run(store: s, taskId: "t-amb", tree: twinned)
        #expect(result.status == "open")
        #expect(result.verdicts.first?.outcome == .ambiguous)
    }

    @Test("a task with no criteria is not auto-verified")
    func noCriteriaUnchanged() throws {
        let s = store()
        _ = try task(id: "t-none", in: s, criteria: [])
        let result = try VerifyTask.run(store: s, taskId: "t-none", tree: tree())
        #expect(result.status == "readyForVerify")
        #expect(result.verdicts.isEmpty)
    }
}
