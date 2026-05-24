/// Pure query predicate over the notes inbox. `notes list` and
/// `notes watch` map their `--status` option through `from(_:)` —
/// parsing is deliberately lenient so an absent or mistyped status
/// collapses to `.all` rather than failing the command.
enum NoteFilter: String, Equatable, Sendable {
    case all
    case queued     // not yet promoted to a review task
    case promoted   // picked up — promoted to a review task

    /// Lenient parse: `nil` or an unrecognised string ⇒ `.all`.
    static func from(_ raw: String?) -> NoteFilter {
        guard let raw else { return .all }
        return NoteFilter(rawValue: raw.lowercased()) ?? .all
    }

    /// Keep the matching notes, preserving input order.
    func apply(to notes: [Note]) -> [Note] {
        switch self {
        case .all:      return notes
        case .queued:   return notes.filter { !$0.promoted }
        case .promoted: return notes.filter { $0.promoted }
        }
    }
}
