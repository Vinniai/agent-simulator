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
