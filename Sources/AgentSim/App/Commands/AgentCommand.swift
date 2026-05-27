import ArgumentParser
import Foundation

struct AgentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Create and inspect agent-simulator feedback loops",
        subcommands: [
            Bootstrap.self,
            Status.self,
            QualityGate.self,
        ]
    )

    struct Bootstrap: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "bootstrap",
            abstract: "Create a review session plus starter tasks for an agentic UI loop"
        )

        @Option(name: .long, help: "Human-readable review session name")
        var name: String = "Agent Sim Loop"

        @Option(name: .long, help: "Project path the agent should edit")
        var project: String = FileManager.default.currentDirectoryPath

        @Option(name: .long, help: "Bundle id for the app under test")
        var bundleId: String?

        @Option(name: .long, help: "Agent id assigned to starter tasks")
        var agentId: String = "agent-simulator"

        @Flag(name: .long, help: "Emit JSON instead of a readable summary")
        var json: Bool = false

        func run() throws {
            let reviewStore = FileReviewStore()
            let taskStore = SQLiteReviewTaskStore()
            let session = try reviewStore.createSession(name: name)
            let context = AgentLoopContext(
                projectPath: URL(fileURLWithPath: project).standardizedFileURL.path,
                qualityGate: "No high recommendations and score >= 8/10",
                loop: [
                    "capture simulator screenshot and accessibility tree",
                    "mark up UI issues against AX elements",
                    "record source changes and diffs",
                    "rerun the flow and attach verification snapshots",
                    "review each screen before closing the task",
                ]
            )
            let contextMarkdown = context.markdown()
            let result = try taskStore.bulkCreateTasks(input: ReviewTaskBulkCreateInput(
                sessionId: session.id,
                defaults: ReviewTaskBulkDefaults(
                    priority: "high",
                    assignee: agentId,
                    instructions: nil,
                    title: nil
                ),
                tasks: [
                    ReviewTaskBulkItem(
                        title: "Capture baseline screens",
                        instructions: "Run the app in the simulator, capture each primary screen, and mark issues with screenshot plus AX evidence.",
                        bundleId: bundleId,
                        contextMarkdown: contextMarkdown
                    ),
                    ReviewTaskBulkItem(
                        title: "Apply UI and DX improvements",
                        instructions: "Implement the marked fixes, record code changes, and keep the app running cleanly in a dev build.",
                        bundleId: bundleId,
                        contextMarkdown: contextMarkdown
                    ),
                    ReviewTaskBulkItem(
                        title: "Verify quality gate",
                        instructions: "Review every updated screen, record the score, and only pass when there are no high recommendations and the score is at least 8/10.",
                        bundleId: bundleId,
                        contextMarkdown: contextMarkdown
                    ),
                ]
            ))

            let output = AgentBootstrapOutput(
                sessionId: session.id,
                reviewURL: "http://127.0.0.1:8421/reviews/\(session.id)",
                tasksCreated: result.created.map(\.id),
                errors: result.errors
            )
            if json {
                try printAgentJSON(output)
            } else {
                print("agent-simulator session: \(output.sessionId)")
                print("review UI: \(output.reviewURL)")
                print("tasks: \(output.tasksCreated.joined(separator: ", "))")
                if !output.errors.isEmpty {
                    print("errors: \(output.errors.count)")
                }
            }
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Summarize review sessions and task states"
        )

        @Option(name: .long, help: "Filter by review session id")
        var sessionId: String?

        @Flag(name: .long, help: "Emit JSON")
        var json: Bool = false

        func run() throws {
            let reviewStore = FileReviewStore()
            let taskStore = SQLiteReviewTaskStore()
            let sessions = try reviewStore.listSessions()
                .filter { sessionId == nil || $0.id == sessionId }
            let tasks = try taskStore.listTasks(sessionId: sessionId, status: nil)
            let summary = AgentStatusOutput(
                reviewRoot: reviewStore.root.path,
                sessionCount: sessions.count,
                taskCount: tasks.count,
                statuses: Dictionary(grouping: tasks, by: \.status)
                    .mapValues(\.count),
                latestSessionId: sessions.first?.id
            )
            if json {
                try printAgentJSON(summary)
            } else {
                print("review root: \(summary.reviewRoot)")
                print("sessions: \(summary.sessionCount)")
                print("tasks: \(summary.taskCount)")
                for key in summary.statuses.keys.sorted() {
                    print("  \(key): \(summary.statuses[key] ?? 0)")
                }
                if let latest = summary.latestSessionId {
                    print("latest: \(latest)")
                }
            }
        }
    }

    struct QualityGate: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "quality-gate",
            abstract: "Record a screen-review score against a task"
        )

        @Argument(help: "Task id")
        var taskId: String

        @Option(name: .long, help: "Numeric screen review score, out of 10")
        var score: Double

        @Option(name: .long, help: "Highest remaining recommendation severity")
        var highestRecommendation: String = "none"

        @Option(name: .long, help: "Optional after snapshot id")
        var afterSnapshotId: String?

        @Option(name: .long, help: "Reviewer or agent id")
        var actor: String = "agent-simulator"

        func run() throws {
            let passed = score >= 8 && !["high", "critical", "p0", "p1"].contains(highestRecommendation.lowercased())
            let notes = "score=\(score)/10; highestRecommendation=\(highestRecommendation); gate=\(passed ? "pass" : "fail")"
            let store = SQLiteReviewTaskStore()
            let task = try store.addVerification(
                taskId: taskId,
                verification: ReviewTaskVerification(
                    id: FileReviewStore.makeID(prefix: "verify"),
                    taskId: taskId,
                    beforeSnapshotIds: [],
                    afterSnapshotId: afterSnapshotId,
                    status: passed ? "pass" : "fail",
                    notes: notes,
                    createdAt: Date()
                )
            )
            _ = try store.appendEvent(taskId: taskId, input: ReviewTaskEventInput(
                type: "quality_gate",
                actor: actor,
                message: notes,
                metadataJSON: #"{"requiredScore":8,"blockedSeverities":["high","critical","p0","p1"]}"#
            ))
            if passed {
                print("pass \(task.id)")
            } else {
                print("fail \(task.id): \(notes)")
            }
        }
    }
}

private struct AgentLoopContext: Codable {
    let projectPath: String
    let qualityGate: String
    let loop: [String]

    func markdown() -> String {
        var lines = [
            "# Agent Sim Loop",
            "",
            "- Project: \(projectPath)",
            "- Quality gate: \(qualityGate)",
            "",
            "## Required Loop",
        ]
        lines.append(contentsOf: loop.map { "- \($0)" })
        return lines.joined(separator: "\n")
    }
}

private struct AgentBootstrapOutput: Codable {
    let sessionId: String
    let reviewURL: String
    let tasksCreated: [String]
    let errors: [ReviewTaskBulkCreateError]
}

private struct AgentStatusOutput: Codable {
    let reviewRoot: String
    let sessionCount: Int
    let taskCount: Int
    let statuses: [String: Int]
    let latestSessionId: String?
}

private func printAgentJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    print(String(decoding: data, as: UTF8.self))
}
