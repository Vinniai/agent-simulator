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
}

enum ReviewTaskStoreError: Error, Equatable {
    case notFound(String)
    case sqlite(String)
}
