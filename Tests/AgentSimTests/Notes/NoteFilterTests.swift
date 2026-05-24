import Testing
import Foundation
@testable import AgentSim

/// `NoteFilter` is the pure query predicate the `notes list` / `notes
/// watch` CLI applies over the inbox. Parsing is lenient — an absent
/// or unrecognised `--status` collapses to `.all` so the command
/// never throws on a typo, it just shows everything.
@Suite("Note filter")
struct NoteFilterTests {

    private func note(_ id: String, promoted: Bool) -> Note {
        Note(id: id, udid: "U", text: id, axPath: nil,
             promoted: promoted, createdAt: Date())
    }

    @Test func `queued keeps only un-promoted notes, order preserved`() {
        let notes = [
            note("a", promoted: false),
            note("b", promoted: true),
            note("c", promoted: false),
        ]
        #expect(NoteFilter.queued.apply(to: notes).map(\.id) == ["a", "c"])
    }

    @Test func `promoted keeps only promoted notes`() {
        let notes = [note("a", promoted: false), note("b", promoted: true)]
        #expect(NoteFilter.promoted.apply(to: notes).map(\.id) == ["b"])
    }

    @Test func `all keeps every note`() {
        let notes = [note("a", promoted: false), note("b", promoted: true)]
        #expect(NoteFilter.all.apply(to: notes).map(\.id) == ["a", "b"])
    }

    @Test func `from parses status, defaulting to all for nil or unknown`() {
        #expect(NoteFilter.from("queued") == .queued)
        #expect(NoteFilter.from("promoted") == .promoted)
        #expect(NoteFilter.from(nil) == .all)
        #expect(NoteFilter.from("garbage") == .all)
    }
}
