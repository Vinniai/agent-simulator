import Testing
import Foundation
@testable import AgentSim

/// Server-handler tests for the session-less notes queue routes.
///
/// As with the bezel routes we test the pure data-producing helpers
/// (`createdNoteJSONString`, `notesInboxJSONString`,
/// `promoteNoteJSONString`) rather than the Hummingbird `Response`
/// builders that wrap them — the route closure stays a thin
/// `Optional<String> → 200 / 4xx` shim over a `Notes` aggregate.
@Suite("Server notes routes")
struct NotesRouteTests {

    @Test func `createdNoteJSONString stores the trimmed message and returns it`() throws {
        let store = InMemoryNotes()

        let json = try #require(Server.createdNoteJSONString(
            NoteCreateInput(udid: "UDID-1", text: "  check empty state  ", axPath: "/win/0/button[Add]"),
            store: store
        ))

        let note = try Self.decoder.decode(Note.self, from: Data(json.utf8))
        #expect(note.udid == "UDID-1")
        #expect(note.text == "check empty state")
        #expect(note.axPath == "/win/0/button[Add]")
        #expect(note.promoted == false)
        #expect(try store.list().count == 1)
    }

    @Test func `notesInboxJSONString returns the inbox newest-first`() throws {
        let store = InMemoryNotes()
        _ = try store.add(NoteCreateInput(udid: "U", text: "first"))
        _ = try store.add(NoteCreateInput(udid: "U", text: "second"))

        let json = try #require(Server.notesInboxJSONString(store: store))

        let inbox = try Self.decoder.decode([Note].self, from: Data(json.utf8))
        #expect(inbox.map(\.text) == ["second", "first"])
    }

    @Test func `promoteNoteJSONString flips the note and creates an anchored review task`() throws {
        let store = InMemoryNotes()
        let tasks = Self.tempTaskStore()
        let note = try store.add(NoteCreateInput(
            udid: "U", text: "Empty state copy is wrong", axPath: "/win[0]/label[Empty]"
        ))

        let json = try #require(
            Server.promoteNoteJSONString(id: note.id, notes: store, taskStore: tasks)
        )

        let result = try Self.decoder.decode(NotePromotionProbe.self, from: Data(json.utf8))
        #expect(result.note.id == note.id)
        #expect(result.note.promoted)
        let task = try #require(result.task)
        #expect(task.sessionId == "notes")
        #expect(task.instructions == "Empty state copy is wrong")
        #expect(task.elements.map(\.axNodePath) == ["/win[0]/label[Empty]"])
        // and it is now discoverable in the shared notes backlog
        #expect(try tasks.listTasks(sessionId: "notes", status: nil).count == 1)
    }

    @Test func `promoteNoteJSONString is nil for an unknown id`() {
        #expect(Server.promoteNoteJSONString(
            id: "ghost", notes: InMemoryNotes(), taskStore: Self.tempTaskStore()
        ) == nil)
    }

    private struct NotePromotionProbe: Decodable {
        let note: Note
        let task: ReviewTask?
    }

    private static func tempTaskStore() -> SQLiteReviewTaskStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-simulator-notes-promote-\(UUID().uuidString)")
        return SQLiteReviewTaskStore(url: dir.appendingPathComponent("tasks.sqlite"))
    }

    @Test func `notesStreamSnapshotJSONString wraps the inbox newest-first under a notes_snapshot envelope`() throws {
        let store = InMemoryNotes()
        _ = try store.add(NoteCreateInput(udid: "U", text: "first"))
        _ = try store.add(NoteCreateInput(udid: "U", text: "second"))

        let json = try #require(Server.notesStreamSnapshotJSONString(store: store, status: nil))

        let snap = try Self.decoder.decode(NotesSnapshotProbe.self, from: Data(json.utf8))
        #expect(snap.type == "notes_snapshot")
        #expect(snap.notes.map(\.text) == ["second", "first"])
    }

    @Test func `notesStreamSnapshotJSONString honours the status filter`() throws {
        let store = InMemoryNotes()
        let promotable = try store.add(NoteCreateInput(udid: "U", text: "picked up one"))
        _ = try store.add(NoteCreateInput(udid: "U", text: "still queued"))
        _ = try store.promote(id: promotable.id)

        let json = try #require(
            Server.notesStreamSnapshotJSONString(store: store, status: "promoted")
        )

        let snap = try Self.decoder.decode(NotesSnapshotProbe.self, from: Data(json.utf8))
        #expect(snap.notes.map(\.text) == ["picked up one"])
        #expect(snap.notes.allSatisfy { $0.promoted })
    }

    private struct NotesSnapshotProbe: Decodable {
        let type: String
        let notes: [Note]
    }

    // MARK: -

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// In-memory `Notes` test double — array-backed, newest-first on read,
/// `notFound` on a missing promote, mirroring `SQLiteNotes`.
private final class InMemoryNotes: Notes, @unchecked Sendable {
    private var notes: [Note] = []

    func add(_ input: NoteCreateInput) throws -> Note {
        let note = Note.from(input, id: "note-\(notes.count + 1)", now: Date())
        notes.append(note)
        return note
    }

    func list() throws -> [Note] { notes.reversed() }

    func promote(id: String) throws -> Note {
        guard let i = notes.firstIndex(where: { $0.id == id }) else {
            throw NotesError.notFound(id)
        }
        notes[i].promoted = true
        return notes[i]
    }
}
