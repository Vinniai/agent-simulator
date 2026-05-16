import Foundation

/// One message left on the session-less queue from the mobile sim
/// view. It has no `sessionId`/task — it stands alone in the inbox
/// until it is promoted into a review task. `axPath` is the optional
/// accessibility node the message was attached to via the on-stream
/// element picker.
struct Note: Codable, Equatable, Sendable {
    let id: String
    let udid: String
    var text: String
    var axPath: String?
    var promoted: Bool
    let createdAt: Date
}

/// The body a left message arrives as: which sim it was taken
/// against, the message text, and an optional picked AX node path.
struct NoteCreateInput: Codable, Equatable, Sendable {
    var udid: String
    var text: String
    var axPath: String?

    init(udid: String, text: String, axPath: String? = nil) {
        self.udid = udid
        self.text = text
        self.axPath = axPath
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
            promoted: false,
            createdAt: now
        )
    }
}
