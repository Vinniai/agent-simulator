import ArgumentParser
import Foundation

/// `agent-simulator notes` — the session-less queue from the CLI.
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

        @Option(
            name: .long,
            help: "Optional source pointer 'file:line[:col]' — same `source` envelope the browser attaches via /triangulate. Useful when an agent has a file location from a stack trace / lint hit but no AX coordinates."
        )
        var source: String?

        func run() throws {
            let body = try readPossiblyStdin(text)
            let parsed = try source.map { try NoteSource.parseFlag($0) }
            try printJSON(SQLiteNotes().add(
                NoteCreateInput(udid: udid, text: body, axPath: axPath, source: parsed)
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

        /// Flip the note *and* file it as a review task in the shared
        /// `notes` backlog (`Note.reviewTaskBulkCreateInput()` — unit
        /// tested). The flag flip is the source of truth for picked-up;
        /// a failed bulk-create still reports the promoted note with a
        /// null task rather than aborting the pick-up.
        func run() throws {
            let note: Note
            do {
                note = try SQLiteNotes().promote(id: id)
            } catch NotesError.notFound {
                throw ValidationError("no note with id '\(id)'")
            }
            let task = (try? SQLiteReviewTaskStore().bulkCreateTasks(
                input: note.reviewTaskBulkCreateInput()
            ))?.created.first
            try printJSON(PromotedNote(note: note, task: task))
        }
    }

    /// `notes promote` output: the picked-up note and the review task
    /// it became (`task` null only when bulk-create produced none).
    private struct PromotedNote: Encodable {
        let note: Note
        let task: ReviewTask?
    }

    struct Watch: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "watch",
            abstract: "Poll — or live-consume — the inbox, printing a JSON line on every change"
        )

        @Option(name: .long, help: "Filter: queued | promoted | all")
        var status: String?

        @Option(name: .long, help: "Polling interval in seconds (poll mode)")
        var interval: Double = 1

        @Flag(name: .long, help: "Print one snapshot and exit")
        var once = false

        @Option(name: .long, help: "POST each changed snapshot to this URL")
        var webhook: String?

        @Option(name: .long, help: "Consume a live WS /notes/stream URL instead of polling local SQLite")
        var stream: String?

        func run() throws {
            let filter = NoteFilter.from(status)
            let hookURL = webhook.flatMap(URL.init(string:))
            if webhook != nil, hookURL == nil {
                throw ValidationError("--webhook is not a valid URL")
            }
            if let stream {
                guard let url = URL(string: stream),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "ws" || scheme == "wss" else {
                    throw ValidationError("--stream must be a ws:// or wss:// URL")
                }
                try runStream(url: url, filter: filter, hookURL: hookURL)
                return
            }
            guard interval > 0 else {
                throw ValidationError("--interval must be greater than zero")
            }
            try runPoll(store: SQLiteNotes(), filter: filter, hookURL: hookURL)
        }

        /// Poll local SQLite, emitting on every inbox change.
        private func runPoll(store: any Notes, filter: NoteFilter, hookURL: URL?) throws {
            var previous = ""
            repeat {
                _ = try emit(filter.apply(to: store.list()),
                             previous: &previous, hookURL: hookURL)
                if once { return }
                Thread.sleep(forTimeInterval: interval)
            } while true
        }

        /// Print a JSON line (and forward it to the webhook) only when
        /// the filtered inbox actually changed. Shared by poll and
        /// stream mode so "what gets emitted" is identical regardless
        /// of how the snapshot arrived. Returns whether it emitted.
        @discardableResult
        private func emit(_ notes: [Note], previous: inout String, hookURL: URL?) throws -> Bool {
            let line = try jsonLine(notes)
            guard line != previous else { return false }
            print(line)
            fflush(stdout)
            previous = line
            if let hookURL { postWebhook(hookURL, body: line) }
            return true
        }

        /// Live-consume `WS /notes/stream`. The frame decode
        /// (`NotesStreamFrame.notes(in:)`) and the change/emit logic
        /// are unit-tested; only the `URLSessionWebSocketTask` receive
        /// loop here is integration-only — bridged to the blocking CLI
        /// with a semaphore exactly like `postWebhook`. Lifecycle and
        /// error frames decode to nil and are skipped; a closed socket
        /// ends the watch (warned on stderr).
        private func runStream(url: URL, filter: NoteFilter, hookURL: URL?) throws {
            let task = URLSession.shared.webSocketTask(with: url)
            task.resume()
            defer { task.cancel(with: .goingAway, reason: nil) }
            var previous = ""
            while true {
                let sem = DispatchSemaphore(value: 0)
                var outcome: Result<URLSessionWebSocketTask.Message, Error>?
                task.receive { outcome = $0; sem.signal() }
                sem.wait()
                switch outcome {
                case .success(let message):
                    let text: String
                    switch message {
                    case .string(let s): text = s
                    case .data(let d):   text = String(decoding: d, as: UTF8.self)
                    @unknown default:    text = ""
                    }
                    guard let notes = NotesStreamFrame.notes(in: text) else { continue }
                    try emit(filter.apply(to: notes), previous: &previous, hookURL: hookURL)
                    if once { return }
                case .failure(let error):
                    FileHandle.standardError.write(Data(
                        "notes stream closed: \(error.localizedDescription)\n".utf8))
                    return
                case .none:
                    return
                }
            }
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
