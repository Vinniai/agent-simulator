import Testing
import Foundation
@testable import AgentSim

/// The operator/agent create-task path (`POST /reviews/:id/tasks`) decodes a
/// `ReviewTaskCreateInput` and builds the persisted `ReviewTask`. Per the
/// house pattern the field-mapping lives in a pure helper
/// (`Server.reviewTaskFromCreateInput`) so it can be unit-tested without a
/// `Request` or a store. The behaviour that matters for ADR-0002: acceptance
/// criteria authored at creation must survive onto the task — otherwise
/// `verify-criteria` would have nothing to check.
@Suite("Create review task field mapping")
struct CreateReviewTaskTests {

    private func input(criteria: [AcceptanceCriterion]?) -> ReviewTaskCreateInput {
        ReviewTaskCreateInput(
            title: "New Task sheet",
            instructions: "Add the sheet",
            priority: "high",
            assignee: "agent-a",
            bundleId: nil,
            snapshotIds: [],
            elements: nil,
            contextMarkdown: nil,
            criteria: criteria)
    }

    private func build(_ input: ReviewTaskCreateInput) -> ReviewTask {
        Server.reviewTaskFromCreateInput(
            taskId: "task-1", sessionId: "review-1", input: input, bundle: nil,
            contextPath: "tasks/task-1/context.md", elements: [], now: Date())
    }

    @Test("authored acceptance criteria carry onto the created task")
    func criteriaCarry() {
        let task = build(input(criteria: [
            AcceptanceCriterion(description: "Save present",
                                selector: ElementSelector(identifier: "save-btn"),
                                expect: .exists),
        ]))
        #expect(task.criteria.count == 1)
        #expect(task.criteria.first?.selector.identifier == "save-btn")
        #expect(task.criteria.first?.expect == .exists)
    }

    @Test("a create with no criteria yields an empty list, never nil-crashes")
    func noCriteria() {
        #expect(build(input(criteria: nil)).criteria.isEmpty)
    }

    @Test("title/priority/assignee map through and status starts open")
    func scalarsMap() {
        let task = build(input(criteria: nil))
        #expect(task.title == "New Task sheet")
        #expect(task.priority == "high")
        #expect(task.assignee == "agent-a")
        #expect(task.status == "open")
    }
}
