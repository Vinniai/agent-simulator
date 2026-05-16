import Testing
import Foundation
@testable import AgentSim

/// `notes watch --stream <ws-url>` consumes `WS /notes/stream`
/// instead of polling local SQLite. `NotesStreamFrame.notes(in:)` is
/// the pure decode of one text frame: the server interleaves
/// `notes_stream_started` / `notes_stream_stopped` / `notes_stream_error`
/// lifecycle frames with `notes_snapshot` payloads, and only the
/// latter carries the inbox the watch loop prints. Everything else
/// decodes to nil so the loop skips it.
@Suite("Notes stream frame decode")
struct NotesStreamFrameTests {

    @Test func `a notes_snapshot frame yields its inbox`() {
        let frame = #"""
        {"type":"notes_snapshot","notes":[\#
        {"id":"n1","udid":"U","text":"hi","promoted":false,"createdAt":"2026-05-15T10:00:00Z"}\#
        ]}
        """#
        #expect(NotesStreamFrame.notes(in: frame)?.map(\.id) == ["n1"])
    }

    @Test func `an empty notes_snapshot yields an empty inbox, not nil`() {
        #expect(NotesStreamFrame.notes(in: #"{"type":"notes_snapshot","notes":[]}"#) == [])
    }

    @Test func `lifecycle and error frames are ignored`() {
        #expect(NotesStreamFrame.notes(in: #"{"type":"notes_stream_started"}"#) == nil)
        #expect(NotesStreamFrame.notes(in: #"{"type":"notes_stream_stopped"}"#) == nil)
        #expect(NotesStreamFrame.notes(
            in: #"{"type":"notes_stream_error","error":"inbox unavailable"}"#
        ) == nil)
    }

    @Test func `unparseable frames are ignored`() {
        #expect(NotesStreamFrame.notes(in: "not json") == nil)
        #expect(NotesStreamFrame.notes(in: "") == nil)
        #expect(NotesStreamFrame.notes(in: "[]") == nil)
    }
}
