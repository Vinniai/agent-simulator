import ArgumentParser
import Foundation

struct ReviewTasksCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "review-tasks",
        abstract: "Poll and update queued review tasks",
        subcommands: [
            List.self,
            Next.self,
            Show.self,
            Claim.self,
            Event.self,
            Result.self,
            Verify.self,
            VerifyCriteria.self,
            Criterion.self,
            AddCodeChange.self,
            BulkCreate.self,
            Watch.self,
        ]
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list")

        @Option(name: .long, help: "Filter by review session id")
        var sessionId: String?

        @Option(name: .long, help: "Filter by task status")
        var status: String?

        func run() throws {
            try printJSON(SQLiteReviewTaskStore().listTasks(sessionId: sessionId, status: status))
        }
    }

    struct Next: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "next")

        @Option(
            name: [.customLong("agent-id"), .customLong("actor")],
            help: "Agent id (or --actor) that should claim the next open task"
        )
        var agentId: String

        func run() throws {
            try printJSON(SQLiteReviewTaskStore().claimNext(agentId: agentId) as ReviewTask?)
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show")

        @Argument(help: "Task id")
        var id: String

        func run() throws {
            try printJSON(SQLiteReviewTaskStore().loadTask(id: id))
        }
    }

    struct Claim: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "claim")

        @Argument(help: "Task id")
        var id: String

        @Option(
            name: [.customLong("agent-id"), .customLong("actor")],
            help: "Agent id (or --actor) recorded as the task's assignee"
        )
        var agentId: String

        func run() throws {
            try printJSON(SQLiteReviewTaskStore().claimTask(id: id, agentId: agentId))
        }
    }

    struct Event: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "event")

        @Argument(help: "Task id")
        var id: String

        @Option(name: .long, help: "Event type, e.g. progress, error, capture")
        var type: String = "progress"

        @Option(name: .long, help: "Actor or agent id")
        var actor: String?

        @Option(name: .long, help: "Event message. Use '-' to read stdin.")
        var message: String

        @Option(name: .long, help: "Optional JSON metadata string")
        var metadataJSON: String?

        func run() throws {
            let body = try readPossiblyStdin(message)
            try printJSON(SQLiteReviewTaskStore().appendEvent(
                taskId: id,
                input: ReviewTaskEventInput(
                    type: type,
                    actor: actor,
                    message: body,
                    metadataJSON: metadataJSON
                )
            ))
        }
    }

    struct Result: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "result")

        @Argument(help: "Task id")
        var id: String

        @Option(name: .long, help: "New status")
        var status: String = "readyForVerify"

        @Option(name: .long, help: "Actor or agent id")
        var actor: String?

        @Option(name: .long, help: "Result summary. Use '-' to read stdin.")
        var summary: String

        @Option(name: .long, help: "Optional verification snapshot id")
        var verificationSnapshotId: String?

        @Option(name: .long, help: "Optional notes")
        var notes: String?

        @Flag(name: .long, help: "After recording the result, grade the task's acceptance criteria against the attached snapshot (ADR-0002 opt-in)")
        var autoVerify = false

        func run() throws {
            let input = ReviewTaskUpdateInput(
                status: status,
                assignee: nil,
                resultSummary: try readPossiblyStdin(summary),
                verificationSnapshotId: verificationSnapshotId,
                notes: notes,
                actor: actor
            )
            try printJSON(LoopRoutes.submitResult(
                autoVerify: autoVerify,
                taskId: id,
                input: input,
                taskStore: SQLiteReviewTaskStore(),
                reviewStore: FileReviewStore()
            ))
        }
    }

    struct Verify: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "verify")

        @Argument(help: "Task id")
        var id: String

        @Option(name: .long, parsing: .upToNextOption, help: "Before snapshot ids")
        var beforeSnapshotId: [String] = []

        @Option(name: .long, help: "After snapshot id")
        var afterSnapshotId: String?

        @Option(name: .long, help: "Verification status")
        var status: String

        @Option(name: .long, help: "Verification notes. Use '-' to read stdin.")
        var notes: String?

        func run() throws {
            let resolvedNotes = try notes.map(readPossiblyStdin)
            try printJSON(SQLiteReviewTaskStore().addVerification(
                taskId: id,
                verification: ReviewTaskVerification(
                    id: FileReviewStore.makeID(prefix: "verify"),
                    taskId: id,
                    beforeSnapshotIds: beforeSnapshotId,
                    afterSnapshotId: afterSnapshotId,
                    status: status,
                    notes: resolvedNotes,
                    createdAt: Date()
                )
            ))
        }
    }

    /// Criteria-based verification (ADR-0002), distinct from the older
    /// manual before/after `verify`. Runs the task's acceptance criteria
    /// through ``CriteriaCheck`` and records the verdicts, driving status
    /// to `verified` (all pass) or back to `open` (any fail). Defaults to
    /// the task's captured verification snapshot — fully reproducible, no
    /// simulator — and switches to a fresh `describe-ui` capture under
    /// `--live --udid`. The verdict engine is identical either way.
    struct VerifyCriteria: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "verify-criteria",
            abstract: "Check a task's acceptance criteria against its snapshot (or --live)"
        )

        @Argument(help: "Task id")
        var id: String

        @Flag(name: .long, help: "Capture a fresh describe-ui tree instead of the snapshot")
        var live = false

        @Option(name: .long, help: "Simulator UDID (required with --live)")
        var udid: String?

        @Option(name: .long, help: "Custom device set path (defaults to Xcode's default set)")
        var deviceSet: String?

        func run() async throws {
            let taskStore = SQLiteReviewTaskStore()
            let result: ReviewTask
            if live {
                guard let udid else {
                    throw ValidationError("--udid is required with --live")
                }
                let simulators = CoreSimulators(deviceSetPath: deviceSet)
                guard let simulator = simulators.find(udid: udid) else {
                    throw ValidationError("Device \(udid) not found")
                }
                guard let tree = try simulator.accessibility().describeAll() else {
                    throw ValidationError("no accessibility data on \(udid) (sim not booted, or no frontmost app)")
                }
                result = try LoopRoutes.verifyLive(taskId: id, tree: tree, taskStore: taskStore)
            } else {
                result = try LoopRoutes.verifyFromSnapshot(
                    taskId: id, taskStore: taskStore, reviewStore: FileReviewStore())
            }
            try printJSON(result)
        }
    }

    /// Author an acceptance criterion straight from a live on-screen element
    /// (ADR-0002), so the loop can turn "this element should be here" into
    /// checkable JSON without hand-writing a selector. Hit-tests the live
    /// `describe-ui` tree at a device-point coordinate (same convention as a
    /// tap), then runs ``AcceptanceCriterion/from(element:)`` — keyed on the
    /// element's `identifier`, else its `label`. Prints the criterion JSON to
    /// drop into a task's `criteria[]`; errors when nothing nameable is there.
    struct Criterion: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "criterion",
            abstract: "Emit an acceptance criterion for the live element at a point"
        )

        @Option(name: .long, help: "Simulator UDID")
        var udid: String

        @Option(name: .long, help: "X coordinate in device points (tap-target convention)")
        var x: Double

        @Option(name: .long, help: "Y coordinate in device points")
        var y: Double

        @Option(name: .long, help: "Custom device set path (defaults to Xcode's default set)")
        var deviceSet: String?

        func run() async throws {
            let simulators = CoreSimulators(deviceSetPath: deviceSet)
            guard let simulator = simulators.find(udid: udid) else {
                throw ValidationError("Device \(udid) not found")
            }
            guard let tree = try simulator.accessibility().describeAll() else {
                throw ValidationError("no accessibility data on \(udid) (sim not booted, or no frontmost app)")
            }
            guard let hit = tree.hitTest(Point(x: x, y: y)) else {
                throw ValidationError("no element at (\(x), \(y)) on \(udid)")
            }
            guard let criterion = AcceptanceCriterion.from(element: hit) else {
                throw ValidationError("element at (\(x), \(y)) has no identifier or label to anchor a criterion")
            }
            try printJSON(criterion)
        }
    }

    struct AddCodeChange: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add-code-change",
            abstract: "Record one or more source-file modifications against a task"
        )

        @Argument(help: "Task id")
        var id: String

        @Option(name: .long, help: "Path to the changed file (absolute path makes VSCode links work)")
        var path: String?

        @Option(name: .long, help: "One-line summary of the change")
        var summary: String?

        @Option(name: .long, help: "First line of the changed range")
        var startLine: Int?

        @Option(name: .long, help: "Last line of the changed range")
        var endLine: Int?

        @Option(name: .long, help: "Commit SHA containing the change")
        var commitSha: String?

        @Option(name: .long, help: "Branch name")
        var branch: String?

        @Option(name: .long, help: "Source language hint (swift, ts, js, …)")
        var language: String?

        @Option(name: .long, help: "Path to a file containing the unified diff")
        var diffFile: String?

        @Option(name: .long, help: "Path to a JSON file with an array of ReviewTaskCodeChangeInput (overrides flags)")
        var changesFile: String?

        @Option(name: .long, help: "Actor or agent id recorded on the event")
        var actor: String?

        func run() throws {
            let changes: [ReviewTaskCodeChangeInput]
            if let changesFile {
                let data = try Data(contentsOf: URL(fileURLWithPath: changesFile))
                changes = try JSONDecoder().decode([ReviewTaskCodeChangeInput].self, from: data)
            } else {
                guard let path else {
                    throw ValidationError("--path is required when --changes-file is not provided")
                }
                let diff: String? = try diffFile.map {
                    try String(contentsOf: URL(fileURLWithPath: $0), encoding: .utf8)
                }
                changes = [
                    ReviewTaskCodeChangeInput(
                        path: path,
                        summary: summary,
                        startLine: startLine,
                        endLine: endLine,
                        commitSha: commitSha,
                        branch: branch,
                        language: language,
                        diffText: diff
                    )
                ]
            }
            try printJSON(SQLiteReviewTaskStore().appendCodeChanges(
                taskId: id,
                input: ReviewTaskCodeChangesInput(actor: actor, changes: changes)
            ))
        }
    }

    struct BulkCreate: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "bulk-create",
            abstract: "Create many review tasks in one call from a JSON file or stdin"
        )

        @Option(name: .long, help: "Review session id every task attaches to")
        var sessionId: String

        @Option(
            name: .long,
            help: "Path to a JSON ReviewTaskBulkCreateInput (tasks[]) or a bare array of ReviewTaskBulkItem. Use '-' for stdin."
        )
        var file: String

        @Option(name: .long, help: "Default priority for items that don't supply one")
        var priority: String?

        @Option(name: .long, help: "Default assignee for items that don't supply one")
        var assignee: String?

        @Option(name: .long, help: "Default instructions for items that don't supply any")
        var instructions: String?

        @Option(name: .long, help: "Default title for items that don't supply one")
        var title: String?

        func run() throws {
            let raw: Data
            if file == "-" {
                raw = FileHandle.standardInput.readDataToEndOfFile()
            } else {
                raw = try Data(contentsOf: URL(fileURLWithPath: file))
            }
            let decoder = JSONDecoder()
            // Accept either the full envelope or a bare items array.
            let items: [ReviewTaskBulkItem]
            var providedDefaults: ReviewTaskBulkDefaults? = nil
            if let envelope = try? decoder.decode(ReviewTaskBulkCreateInput.self, from: raw) {
                items = envelope.tasks
                providedDefaults = envelope.defaults
            } else {
                items = try decoder.decode([ReviewTaskBulkItem].self, from: raw)
            }
            let cliDefaults = ReviewTaskBulkDefaults(
                priority: priority,
                assignee: assignee,
                instructions: instructions,
                title: title
            )
            let defaults = merge(file: providedDefaults, cli: cliDefaults)
            try printJSON(SQLiteReviewTaskStore().bulkCreateTasks(
                input: ReviewTaskBulkCreateInput(
                    sessionId: sessionId,
                    defaults: defaults,
                    tasks: items
                )
            ))
        }

        /// CLI-level overrides win over file-level defaults so an
        /// operator can re-tag a batch (e.g. assign all to a single
        /// agent) without rewriting the JSON.
        private func merge(
            file fileDefaults: ReviewTaskBulkDefaults?,
            cli: ReviewTaskBulkDefaults
        ) -> ReviewTaskBulkDefaults? {
            let merged = ReviewTaskBulkDefaults(
                priority: cli.priority ?? fileDefaults?.priority,
                assignee: cli.assignee ?? fileDefaults?.assignee,
                instructions: cli.instructions ?? fileDefaults?.instructions,
                title: cli.title ?? fileDefaults?.title
            )
            if merged.priority == nil && merged.assignee == nil
                && merged.instructions == nil && merged.title == nil {
                return nil
            }
            return merged
        }
    }

    struct Watch: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "watch",
            abstract: "Poll queued review tasks and print JSON lines when they change"
        )

        @Option(name: .long, help: "Filter by review session id")
        var sessionId: String?

        @Option(name: .long, help: "Filter by task status")
        var status: String?

        @Option(name: .long, help: "Polling interval in seconds")
        var interval: Double = 1

        @Flag(name: .long, help: "Print one snapshot and exit")
        var once = false

        func run() throws {
            guard interval > 0 else {
                throw ValidationError("--interval must be greater than zero")
            }
            let store = SQLiteReviewTaskStore()
            var previous = ""
            repeat {
                let tasks = try store.listTasks(sessionId: sessionId, status: status)
                let line = try jsonLine(tasks)
                if line != previous {
                    print(line)
                    fflush(stdout)
                    previous = line
                }
                if once { return }
                Thread.sleep(forTimeInterval: interval)
            } while true
        }
    }
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    print(String(decoding: data, as: UTF8.self))
}

private func jsonLine<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    return String(decoding: data, as: UTF8.self)
}

private func readPossiblyStdin(_ value: String) throws -> String {
    guard value == "-" else { return value }
    return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
}
