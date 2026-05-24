import Foundation
import Testing
@testable import AgentSim

/// `NoteSource` is the triangulation envelope a note carries along
/// for agents picking the queue up: the workspace the running app
/// was built from, plus the ranked source-file candidates the JSX
/// scanner produced for the AX anchor. The browser POSTs the same
/// `{workspace, candidates}` shape `/triangulate` returns; the
/// server persists it verbatim so `GET /notes.json` (and the
/// `notes/stream` WS) hand it back unchanged.
@Suite("NoteSource")
struct NoteSourceTests {

    private func freshStore() -> SQLiteNotes {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-sim-notes-source-tests-\(UUID().uuidString)")
        return SQLiteNotes(url: dir.appendingPathComponent("notes.sqlite"))
    }

    private let sample = NoteSource(
        workspace: NoteSource.WorkspaceRef(
            root: "/Users/x/projects/mobile",
            framework: "expoRouter"
        ),
        candidates: [
            NoteSource.CandidateRef(
                file: "/Users/x/projects/mobile/app/index.tsx",
                line: 42, column: 17, confidence: 0.9, component: "Pressable"
            ),
            NoteSource.CandidateRef(
                file: "/Users/x/projects/mobile/features/agenda.tsx",
                line: 480, column: 17, confidence: 0.8, component: "Text"
            ),
        ]
    )

    @Test("Note.from copies source through from the create input")
    func from_preserves_source() {
        let input = NoteCreateInput(
            udid: "UDID-1", text: "Schedule's clear",
            axPath: "/window/0/text[Schedule's clear]",
            source: sample
        )
        let note = Note.from(input, id: "note_1", now: Date())
        #expect(note.source == sample)
        #expect(note.source?.candidates.count == 2)
        #expect(note.source?.candidates.first?.confidence == 0.9)
    }

    @Test("SQLiteNotes round-trips source through add → list")
    func sqlite_roundtrip() throws {
        let notes = freshStore()
        let stored = try notes.add(
            NoteCreateInput(
                udid: "UDID-1", text: "fix copy",
                axPath: "/window/0/text[Foo]",
                source: sample
            )
        )
        let listed = try notes.list().first
        #expect(stored.source == sample)
        #expect(listed?.source == sample)
        #expect(listed?.source?.workspace?.framework == "expoRouter")
        #expect(listed?.source?.candidates[1].component == "Text")
    }

    @Test("a note posted with no source has source == nil after round-trip")
    func sqlite_no_source_stays_nil() throws {
        let notes = freshStore()
        _ = try notes.add(
            NoteCreateInput(udid: "UDID-1", text: "hi", axPath: nil)
        )
        #expect(try notes.list().first?.source == nil)
    }

    @Test("NoteSource.parseFlag parses file:line and file:line:col")
    func parse_flag() throws {
        let a = try NoteSource.parseFlag("app/index.tsx:42")
        #expect(a.candidates.count == 1)
        #expect(a.candidates[0].file == "app/index.tsx")
        #expect(a.candidates[0].line == 42)
        #expect(a.candidates[0].column == 1)
        #expect(a.candidates[0].confidence == 1.0)
        #expect(a.workspace == nil)

        let b = try NoteSource.parseFlag("/abs/path/screen.tsx:480:17")
        #expect(b.candidates[0].file == "/abs/path/screen.tsx")
        #expect(b.candidates[0].line == 480)
        #expect(b.candidates[0].column == 17)
    }

    @Test("NoteSource.parseFlag rejects malformed inputs")
    func parse_flag_rejects() {
        #expect(throws: (any Error).self) { try NoteSource.parseFlag("no-line") }
        #expect(throws: (any Error).self) { try NoteSource.parseFlag("file.tsx:notnum") }
        #expect(throws: (any Error).self) { try NoteSource.parseFlag(":42") }
        #expect(throws: (any Error).self) { try NoteSource.parseFlag("") }
    }

    @Test("Note encodes source as the same wire shape /triangulate returns")
    func note_encode_matches_triangulate_shape() throws {
        let note = Note(
            id: "note_1", udid: "UDID-1", text: "x",
            axPath: nil, source: sample,
            promoted: false, createdAt: Date(timeIntervalSince1970: 0)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(note)
        let obj = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let source = try #require(obj["source"] as? [String: Any])
        let workspace = try #require(source["workspace"] as? [String: Any])
        #expect((workspace["framework"] as? String) == "expoRouter")
        #expect((workspace["root"] as? String) == "/Users/x/projects/mobile")
        let candidates = try #require(source["candidates"] as? [[String: Any]])
        #expect(candidates.count == 2)
        #expect((candidates.first?["file"] as? String)?.hasSuffix("/app/index.tsx") == true)
        #expect((candidates.first?["confidence"] as? Double) == 0.9)
        #expect((candidates.first?["component"] as? String) == "Pressable")
    }
}
