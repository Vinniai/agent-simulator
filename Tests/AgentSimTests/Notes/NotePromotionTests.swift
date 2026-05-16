import Testing
import Foundation
@testable import AgentSim

/// Promoting a queued note doesn't just flip a flag — it becomes a
/// real review task. `Note.reviewTaskBulkCreateInput()` is the pure
/// mapping the `notes promote` CLI and `POST /notes/:id/promote` route
/// feed into `ReviewTaskStore.bulkCreateTasks`: one item, under a
/// shared session-less `notes` session, anchored to the picked AX
/// node when the note carried one.
@Suite("Note promotion → review task")
struct NotePromotionTests {

    private func note(text: String, axPath: String? = nil) -> Note {
        Note(id: "n1", udid: "UDID-9", text: text, axPath: axPath,
             promoted: false, createdAt: Date())
    }

    @Test func `maps to a single-item batch under the shared notes session`() {
        let input = note(text: "Empty state shows the wrong copy")
            .reviewTaskBulkCreateInput()
        #expect(input.sessionId == "notes")
        #expect(input.tasks.count == 1)
    }

    @Test func `the note text becomes the task instructions`() {
        let input = note(text: "Button is misaligned on iPhone SE")
            .reviewTaskBulkCreateInput()
        #expect(input.tasks[0].instructions == "Button is misaligned on iPhone SE")
    }

    @Test func `the title is the first line; over-long titles are truncated`() {
        #expect(
            note(text: "first line\nsecond line")
                .reviewTaskBulkCreateInput().tasks[0].title == "first line"
        )
        let long = note(text: String(repeating: "x", count: 120))
            .reviewTaskBulkCreateInput().tasks[0].title
        #expect(long?.count == 80)
        #expect(long?.hasSuffix("…") == true)
    }

    @Test func `a picked AX path becomes the task's anchored element`() {
        let els = note(text: "fix this", axPath: "/win[0]/button[Add]")
            .reviewTaskBulkCreateInput().tasks[0].elements
        #expect(els.count == 1)
        #expect(els[0].axNodePath == "/win[0]/button[Add]")
        #expect(els[0].commentText == "fix this")
        #expect(els[0].snapshotId == "")
    }

    @Test func `no AX path yields an element-free task`() {
        #expect(
            note(text: "general feedback")
                .reviewTaskBulkCreateInput().tasks[0].elements.isEmpty
        )
    }
}
