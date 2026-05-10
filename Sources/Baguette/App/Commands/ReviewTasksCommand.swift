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

        @Option(name: .long, help: "Agent id that should claim the next open task")
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

        @Option(name: .long, help: "Agent id")
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

        func run() throws {
            try printJSON(SQLiteReviewTaskStore().updateTask(
                id: id,
                input: ReviewTaskUpdateInput(
                    status: status,
                    assignee: nil,
                    resultSummary: readPossiblyStdin(summary),
                    verificationSnapshotId: verificationSnapshotId,
                    notes: notes,
                    actor: actor
                )
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
