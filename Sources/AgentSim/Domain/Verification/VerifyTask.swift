import Foundation

/// The authoritative verify use-case (ADR-0002). Pulls a task from the
/// store, runs its acceptance criteria through ``CriteriaCheck`` against a
/// supplied AX tree, records the verdicts, and drives status:
///
/// - every criterion passes → `verified`
/// - any fail or ambiguous   → `open` (back to the queue)
/// - no criteria at all       → unchanged (nothing to verify, never
///   silently "verified")
///
/// The tree is the caller's concern — a captured snapshot's `axPath` by
/// default, or live `describe-ui` under `--live` — so this stays pure
/// orchestration and is testable against any ``ReviewTaskStore`` with a
/// fixture tree.
enum VerifyTask {
    static func run(
        store: any ReviewTaskStore,
        taskId: String,
        tree: AXNode
    ) throws -> ReviewTask {
        let task = try store.loadTask(id: taskId)
        guard !task.criteria.isEmpty else { return task }

        let verdicts = CriteriaCheck.run(tree: tree, criteria: task.criteria)
        let allPass = verdicts.allSatisfy { $0.outcome == .pass }
        let status = allPass ? "verified" : "open"
        return try store.recordVerdicts(taskId: taskId, verdicts: verdicts, status: status)
    }
}
