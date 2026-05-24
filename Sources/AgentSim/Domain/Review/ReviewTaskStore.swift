import Foundation

protocol ReviewTaskStore: Sendable {
    func createTask(_ task: ReviewTask) throws -> ReviewTask
    func listTasks(sessionId: String?, status: String?) throws -> [ReviewTask]
    func loadTask(id: String) throws -> ReviewTask
    func claimNext(agentId: String) throws -> ReviewTask?
    func claimTask(id: String, agentId: String) throws -> ReviewTask
    func appendEvent(taskId: String, input: ReviewTaskEventInput) throws -> ReviewTask
    func updateTask(id: String, input: ReviewTaskUpdateInput) throws -> ReviewTask
    func addVerification(taskId: String, verification: ReviewTaskVerification) throws -> ReviewTask
    func appendCodeChanges(taskId: String, input: ReviewTaskCodeChangesInput) throws -> ReviewTask
    /// Persist the verdicts from a verification pass and set the resulting
    /// status atomically (ADR-0002). Replaces any prior verdicts.
    func recordVerdicts(taskId: String, verdicts: [Verdict], status: String) throws -> ReviewTask
    func bulkCreateTasks(input: ReviewTaskBulkCreateInput) throws -> ReviewTaskBulkCreateResult
}

enum ReviewTaskStoreError: Error, Equatable {
    case notFound(String)
    case sqlite(String)
}
