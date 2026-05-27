import Foundation
import Testing
@testable import AgentSim

/// The session-less notes queue. A message left from the mobile sim
/// view (`/m/:udid`) is appended without a sessionId or task, comes
/// back in the inbox newest-first, and can later be promoted into a
/// review task. These tests pin that queue contract.
@Suite("Notes queue")
struct NotesQueueTests {

    private func freshStore() -> SQLiteNotes {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-simulator-notes-tests-\(UUID().uuidString)")
        return SQLiteNotes(url: dir.appendingPathComponent("notes.sqlite"))
    }

    @Test("a left message is appended and returned in the inbox newest-first")
    func appendAndList() throws {
        let notes = freshStore()
        let first = try notes.add(
            NoteCreateInput(udid: "UDID-1", text: "  check the empty state  ", axPath: nil)
        )
        let second = try notes.add(
            NoteCreateInput(
                udid: "UDID-1",
                text: "title truncates",
                axPath: "/window/0/button[Add]"
            )
        )

        let inbox = try notes.list()

        #expect(inbox.map(\.id) == [second.id, first.id])
        #expect(inbox.first?.text == "title truncates")
        #expect(inbox.first?.axPath == "/window/0/button[Add]")
        #expect(inbox.first?.udid == "UDID-1")
        #expect(inbox.allSatisfy { $0.promoted == false })
        // leading/trailing whitespace is trimmed on the way in
        #expect(inbox.last?.text == "check the empty state")
        #expect(inbox.last?.axPath == nil)
    }

    @Test("promoting a note flips it to promoted and survives a reload")
    func promote() throws {
        let notes = freshStore()
        let note = try notes.add(
            NoteCreateInput(udid: "UDID-1", text: "ship it", axPath: nil)
        )

        let promoted = try notes.promote(id: note.id)

        #expect(promoted.promoted)
        #expect(promoted.id == note.id)
        #expect(try notes.list().first?.promoted == true)
    }

    @Test("promoting a missing note reports it not found")
    func promoteMissing() {
        let notes = freshStore()
        #expect(throws: NotesError.notFound("nope")) {
            try notes.promote(id: "nope")
        }
    }
}
