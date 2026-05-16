import ArgumentParser
import Foundation

/// `agent-sim notes` — the session-less queue from the CLI.
///
/// Sending events: `add` appends a message (optionally anchored to an
/// AX path), `promote` flips one to picked-up. Listening: `list`
/// prints the inbox once; `watch` polls and emits a JSON line on
/// every change, optionally POSTing it to a `--webhook` URL so an
/// external agent learns of new queue items out of band. The store
/// is the same `notes.sqlite` the `serve` mobile screen writes to, so
/// a note left on a phone is visible here within one poll and vice
/// versa.
struct NotesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notes",
        abstract: "Send to and listen on the session-less notes queue",
        subcommands: [List.self, Add.self, Promote.self, Watch.self]
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "Print the inbox (newest first) as JSON"
        )

        @Option(name: .long, help: "Filter: queued | promoted | all")
        var status: String?

        func run() throws {
            let notes = try SQLiteNotes().list()
            try printJSON(NoteFilter.from(status).apply(to: notes))
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Append a message onto the queue"
        )

        @Option(name: .long, help: "Simulator UDID the note is about")
        var udid: String

        @Option(name: .long, help: "Message text. Use '-' to read stdin.")
        var text: String

        @Option(name: .long, help: "Optional AX path the note anchors to")
        var axPath: String?

        func run() throws {
            let body = try readPossiblyStdin(text)
            try printJSON(SQLiteNotes().add(
                NoteCreateInput(udid: udid, text: body, axPath: axPath)
            ))
        }
    }

    struct Promote: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "promote",
            abstract: "Flip a note to picked-up (it became a review task)"
        )

        @Argument(help: "Note id")
        var id: String

        func run() throws {
            do {
                try printJSON(SQLiteNotes().promote(id: id))
            } catch NotesError.notFound {
                throw ValidationError("no note with id '\(id)'")
            }
        }
    }

    struct Watch: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "watch",
            abstract: "Poll the inbox; print a JSON line whenever it changes"
        )

        @Option(name: .long, help: "Filter: queued | promoted | all")
        var status: String?

        @Option(name: .long, help: "Polling interval in seconds")
        var interval: Double = 1

        @Flag(name: .long, help: "Print one snapshot and exit")
        var once = false

        @Option(name: .long, help: "POST each changed snapshot to this URL")
        var webhook: String?

        func run() throws {
            guard interval > 0 else {
                throw ValidationError("--interval must be greater than zero")
            }
            let store = SQLiteNotes()
            let filter = NoteFilter.from(status)
            let hookURL = webhook.flatMap(URL.init(string:))
            if webhook != nil, hookURL == nil {
                throw ValidationError("--webhook is not a valid URL")
            }
            var previous = ""
            repeat {
                let notes = filter.apply(to: try store.list())
                let line = try jsonLine(notes)
                if line != previous {
                    print(line)
                    fflush(stdout)
                    previous = line
                    if let hookURL { postWebhook(hookURL, body: line) }
                }
                if once { return }
                Thread.sleep(forTimeInterval: interval)
            } while true
        }

        /// Best-effort fire-and-wait POST. The CLI is a blocking
        /// `repeat` loop so we wait on the delivery (with a short
        /// ceiling) and warn on failure rather than silently dropping
        /// — but a down endpoint never stalls the watch beyond the
        /// timeout. The network call itself is the only
        /// integration-only line here.
        private func postWebhook(_ url: URL, body: String) {
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(body.utf8)
            let sem = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: req) { _, resp, err in
                if let err {
                    FileHandle.standardError.write(Data(
                        "webhook POST failed: \(err.localizedDescription)\n".utf8))
                } else if let http = resp as? HTTPURLResponse,
                          !(200..<300).contains(http.statusCode) {
                    FileHandle.standardError.write(Data(
                        "webhook POST \(http.statusCode)\n".utf8))
                }
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 12)
        }
    }
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

private func jsonLine<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func readPossiblyStdin(_ value: String) throws -> String {
    guard value == "-" else { return value }
    return String(decoding: FileHandle.standardInput.readDataToEndOfFile(),
                  as: UTF8.self)
}
