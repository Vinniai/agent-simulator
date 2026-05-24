import Foundation
import SQLite3

/// SQLite-backed notes inbox. One flat table next to the review
/// `tasks.sqlite`; the inbox is ordered by `rowid` (monotonic per
/// insert) so newest-first is deterministic even when two messages
/// land in the same ISO-8601 second. Mirrors `SQLiteReviewTaskStore`'s
/// lock / prepare / bind shape.
final class SQLiteNotes: Notes, @unchecked Sendable {
    private let dbPath: String
    private let lock = NSLock()
    private var db: OpaquePointer?

    init(url: URL = FileReviewStore.defaultRoot().appendingPathComponent("notes.sqlite")) {
        self.dbPath = url.path
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        sqlite3_open(dbPath, &db)
        try? exec("PRAGMA journal_mode=WAL")
        try? migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    func add(_ input: NoteCreateInput) throws -> Note {
        try locked {
            let note = Note.from(
                input,
                id: FileReviewStore.makeID(prefix: "note"),
                now: Date()
            )
            try run(
                """
                INSERT INTO notes (id, udid, text, ax_path, source_json, promoted, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    note.id, note.udid, note.text, note.axPath,
                    encodeSource(note.source),
                    note.promoted ? "1" : "0", iso(note.createdAt)
                ]
            )
            return note
        }
    }

    func list() throws -> [Note] {
        try locked {
            try query(
                "SELECT id, udid, text, ax_path, source_json, promoted, created_at FROM notes ORDER BY rowid DESC",
                []
            ) { try self.hydrate($0) }
        }
    }

    func promote(id: String) throws -> Note {
        try locked {
            try run("UPDATE notes SET promoted = 1 WHERE id = ?", [id])
            guard sqlite3_changes(db) > 0 else {
                throw NotesError.notFound(id)
            }
            let rows = try query(
                "SELECT id, udid, text, ax_path, source_json, promoted, created_at FROM notes WHERE id = ?",
                [id]
            ) { try self.hydrate($0) }
            guard let note = rows.first else { throw NotesError.notFound(id) }
            return note
        }
    }

    // MARK: -

    private func hydrate(_ stmt: OpaquePointer?) throws -> Note {
        Note(
            id: text(stmt, 0) ?? "",
            udid: text(stmt, 1) ?? "",
            text: text(stmt, 2) ?? "",
            axPath: text(stmt, 3),
            source: decodeSource(text(stmt, 4)),
            promoted: (text(stmt, 5) ?? "0") == "1",
            createdAt: date(text(stmt, 6) ?? "")
        )
    }

    private func migrate() throws {
        try exec(
            """
            CREATE TABLE IF NOT EXISTS notes (
              id TEXT PRIMARY KEY,
              udid TEXT NOT NULL,
              text TEXT NOT NULL,
              ax_path TEXT,
              promoted INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL
            )
            """
        )
        // Schema v2: `source_json` carries the triangulation envelope
        // (workspace + ranked candidates) the browser already fetched
        // when the note was posted. Added as a nullable column so old
        // rows keep working untouched.
        try addColumnIfMissing(table: "notes", column: "source_json", definition: "TEXT")
    }

    private func addColumnIfMissing(
        table: String, column: String, definition: String
    ) throws {
        let cols = try query("PRAGMA table_info(\(table))", []) { stmt -> String in
            self.text(stmt, 1) ?? ""
        }
        if cols.contains(column) { return }
        try exec("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }

    private func encodeSource(_ source: NoteSource?) -> String? {
        guard let source else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(source) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeSource(_ json: String?) -> NoteSource? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(NoteSource.self, from: data)
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NotesError.sqlite(lastError)
        }
    }

    private func run(_ sql: String, _ args: [Any?]) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NotesError.sqlite(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        try bind(args, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NotesError.sqlite(lastError)
        }
    }

    private func query<T>(
        _ sql: String,
        _ args: [Any?],
        map: (OpaquePointer?) throws -> T
    ) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NotesError.sqlite(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        try bind(args, to: stmt)
        var rows: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(try map(stmt))
        }
        return rows
    }

    private func bind(_ args: [Any?], to stmt: OpaquePointer?) throws {
        for (index, value) in args.enumerated() {
            let slot = Int32(index + 1)
            if value == nil {
                sqlite3_bind_null(stmt, slot)
            } else if let value = value as? String {
                sqlite3_bind_text(stmt, slot, value, -1, SQLITE_TRANSIENT_NOTES)
            } else {
                sqlite3_bind_text(stmt, slot, String(describing: value!), -1, SQLITE_TRANSIENT_NOTES)
            }
        }
    }

    private var lastError: String {
        String(cString: sqlite3_errmsg(db))
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? Date(timeIntervalSince1970: 0)
    }

    private func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: pointer)
    }
}

private let SQLITE_TRANSIENT_NOTES = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
