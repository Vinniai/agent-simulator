import Foundation

/// One message left on the session-less queue from the mobile sim
/// view. It has no `sessionId`/task — it stands alone in the inbox
/// until it is promoted into a review task. `axPath` is the optional
/// accessibility node the message was attached to via the on-stream
/// element picker; `source` is the optional source-file triangulation
/// the browser had already resolved for that node when the note was
/// posted, so an agent fetching the queue lands directly on the file
/// + line that produced the screen element.
struct Note: Codable, Equatable, Sendable {
    let id: String
    let udid: String
    var text: String
    var axPath: String?
    var source: NoteSource?
    var promoted: Bool
    let createdAt: Date
}

/// The body a left message arrives as: which sim it was taken
/// against, the message text, an optional picked AX node path, and
/// the triangulation result the browser already fetched for that
/// node (the same `{workspace, candidates}` shape `/triangulate`
/// returns). The server persists `source` verbatim — it is the
/// browser's already-paid-for compute, not re-derived on submit.
struct NoteCreateInput: Codable, Equatable, Sendable {
    var udid: String
    var text: String
    var axPath: String?
    var source: NoteSource?

    init(
        udid: String, text: String,
        axPath: String? = nil, source: NoteSource? = nil
    ) {
        self.udid = udid
        self.text = text
        self.axPath = axPath
        self.source = source
    }
}

/// Mirror of the JSON the browser receives back from `POST
/// /triangulate`, in a Codable shape so the same payload can be
/// persisted with the note. Paths are kept as strings (not `URL`)
/// to round-trip exactly — `URL` adds a trailing-slash dance JSON
/// agents shouldn't have to second-guess.
struct NoteSource: Codable, Equatable, Sendable {
    var workspace: WorkspaceRef?
    var candidates: [CandidateRef]

    struct WorkspaceRef: Codable, Equatable, Sendable {
        var root: String
        var framework: String
    }

    struct CandidateRef: Codable, Equatable, Sendable {
        var file: String
        var line: Int
        var column: Int
        var confidence: Double
        var component: String?
    }

    /// Parse a CLI-friendly `file:line[:col]` flag into a one-candidate
    /// `NoteSource` with no workspace. Confidence is pinned to `1.0` —
    /// the agent is asserting the pointer, not guessing from a scan.
    static func parseFlag(_ raw: String) throws -> NoteSource {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let file = parts.first.map(String.init), !file.isEmpty,
              let line = Int(parts[1]), line > 0
        else {
            throw NoteSourceFlagError.malformed(raw)
        }
        let col: Int
        if parts.count == 3 {
            guard let c = Int(parts[2]), c > 0 else {
                throw NoteSourceFlagError.malformed(raw)
            }
            col = c
        } else {
            col = 1
        }
        return NoteSource(
            workspace: nil,
            candidates: [CandidateRef(
                file: file, line: line, column: col,
                confidence: 1.0, component: nil
            )]
        )
    }
}

enum NoteSourceFlagError: Error, CustomStringConvertible {
    case malformed(String)
    var description: String {
        switch self {
        case .malformed(let raw):
            return "--source must look like 'file:line' or 'file:line:col' (got '\(raw)')"
        }
    }
}

extension Note {
    /// The session-less notes queue feeds promoted notes into the
    /// review-task backlog under one shared session id, so a single
    /// `GET /review-tasks.json?sessionId=notes` lists everything that
    /// was picked up off a phone.
    static let promotedSessionId = "notes"

    /// Map this note onto a one-item bulk-create batch — the pure
    /// half of "promote a note ⇒ create a review task". The full text
    /// is the task instructions; its first line (truncated at 80) the
    /// title; a picked AX path becomes a single anchored element that
    /// carries the note text as its comment. No element when the note
    /// wasn't anchored — bulk-create accepts an element-free task.
    func reviewTaskBulkCreateInput() -> ReviewTaskBulkCreateInput {
        let firstLine = text.split(
            separator: "\n", maxSplits: 1, omittingEmptySubsequences: false
        ).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let title: String? = firstLine.isEmpty
            ? nil
            : (firstLine.count > 80
                ? String(firstLine.prefix(79)) + "…"
                : firstLine)
        let elements: [ReviewTaskElementInput] = axPath.map {
            [ReviewTaskElementInput(snapshotId: "", axNodePath: $0, commentText: text)]
        } ?? []
        return ReviewTaskBulkCreateInput(
            sessionId: Note.promotedSessionId,
            defaults: nil,
            tasks: [ReviewTaskBulkItem(
                title: title,
                instructions: text,
                elements: elements
            )]
        )
    }

    /// Build a fresh, un-promoted note from a left message. Text and
    /// `axPath` are trimmed; a blank `axPath` collapses to `nil` so the
    /// inbox never carries an empty-string selector.
    static func from(_ input: NoteCreateInput, id: String, now: Date) -> Note {
        let ax = input.axPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Note(
            id: id,
            udid: input.udid,
            text: input.text.trimmingCharacters(in: .whitespacesAndNewlines),
            axPath: (ax?.isEmpty == false) ? ax : nil,
            source: input.source,
            promoted: false,
            createdAt: now
        )
    }
}
