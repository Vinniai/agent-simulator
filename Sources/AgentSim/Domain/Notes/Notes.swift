import Foundation

/// Aggregate persistence for the session-less notes queue. Spelled as
/// the plural of the `Note` aggregate (cf. `Simulators`, `Chromes`):
/// append a left message, read the inbox newest-first, promote one by
/// identity. No `Store`/`Repository` suffix — the role *is* the
/// aggregate collection.
protocol Notes: Sendable {
    /// Append a left message; returns the stored, un-promoted note.
    func add(_ input: NoteCreateInput) throws -> Note
    /// The inbox, newest message first.
    func list() throws -> [Note]
    /// Flip a note to promoted (it has become a review task).
    func promote(id: String) throws -> Note
}

enum NotesError: Error, Equatable {
    case notFound(String)
    case sqlite(String)
}
