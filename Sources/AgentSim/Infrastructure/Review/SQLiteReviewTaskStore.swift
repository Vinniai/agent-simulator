import Foundation
import SQLite3

final class SQLiteReviewTaskStore: ReviewTaskStore, @unchecked Sendable {
    private let dbPath: String
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var db: OpaquePointer?

    init(url: URL = FileReviewStore.defaultRoot().appendingPathComponent("tasks.sqlite")) {
        self.dbPath = url.path
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        sqlite3_open(dbPath, &db)
        try? exec("PRAGMA journal_mode=WAL")
        try? exec("PRAGMA foreign_keys=ON")
        try? migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    func createTask(_ task: ReviewTask) throws -> ReviewTask {
        try locked {
            try insertTask(task)
            for element in task.elements { try insertElement(element) }
            for event in task.events { try insertEvent(event) }
            return try loadTaskUnlocked(id: task.id)
        }
    }

    func listTasks(sessionId: String? = nil, status: String? = nil) throws -> [ReviewTask] {
        try locked {
            var clauses: [String] = []
            var args: [String] = []
            if let sessionId {
                clauses.append("session_id = ?")
                args.append(sessionId)
            }
            if let status {
                clauses.append("status = ?")
                args.append(status)
            }
            let whereSQL = clauses.isEmpty ? "" : " WHERE \(clauses.joined(separator: " AND "))"
            return try queryTaskRows(
                "SELECT * FROM review_tasks\(whereSQL) ORDER BY updated_at DESC",
                args
            ).map { try hydrate($0) }
        }
    }

    func loadTask(id: String) throws -> ReviewTask {
        try locked { try loadTaskUnlocked(id: id) }
    }

    func claimNext(agentId: String) throws -> ReviewTask? {
        try locked {
            let rows = try queryTaskRows(
                "SELECT * FROM review_tasks WHERE status = ? ORDER BY created_at ASC LIMIT 1",
                ["open"]
            )
            guard let row = rows.first else { return nil }
            return try claimTaskUnlocked(id: row.id, agentId: agentId)
        }
    }

    func claimTask(id: String, agentId: String) throws -> ReviewTask {
        try locked { try claimTaskUnlocked(id: id, agentId: agentId) }
    }

    func appendEvent(taskId: String, input: ReviewTaskEventInput) throws -> ReviewTask {
        try locked {
            _ = try loadTaskUnlocked(id: taskId)
            try insertEvent(ReviewTaskEvent(
                id: FileReviewStore.makeID(prefix: "event"),
                taskId: taskId,
                type: input.type,
                actor: input.actor,
                message: input.message,
                metadataJSON: input.metadataJSON,
                createdAt: Date()
            ))
            try run(
                "UPDATE review_tasks SET updated_at = ? WHERE id = ?",
                [iso(Date()), taskId]
            )
            return try loadTaskUnlocked(id: taskId)
        }
    }

    func updateTask(id: String, input: ReviewTaskUpdateInput) throws -> ReviewTask {
        try locked {
            var task = try loadTaskUnlocked(id: id)
            if let status = input.status { task.status = status }
            if let assignee = input.assignee { task.assignee = assignee }
            if let summary = input.resultSummary { task.resultSummary = summary }
            if let snapshotId = input.verificationSnapshotId { task.verificationSnapshotId = snapshotId }
            if ["verified", "failed", "cancelled"].contains(task.status) {
                task.completedAt = Date()
            }
            task.updatedAt = Date()
            try updateTaskRow(task)
            try insertEvent(ReviewTaskEvent(
                id: FileReviewStore.makeID(prefix: "event"),
                taskId: id,
                type: input.status.map { "status:\($0)" } ?? "update",
                actor: input.actor,
                message: input.notes ?? input.resultSummary ?? "Task updated",
                metadataJSON: nil,
                createdAt: Date()
            ))
            return try loadTaskUnlocked(id: id)
        }
    }

    func bulkCreateTasks(input: ReviewTaskBulkCreateInput) throws -> ReviewTaskBulkCreateResult {
        var created: [ReviewTask] = []
        var errors: [ReviewTaskBulkCreateError] = []
        for (index, item) in input.tasks.enumerated() {
            do {
                let task = try buildBulkTask(
                    item: item,
                    defaults: input.defaults,
                    sessionId: input.sessionId,
                    index: index
                )
                let stored = try createTask(task)
                created.append(stored)
            } catch let error as ReviewTaskStoreError {
                errors.append(ReviewTaskBulkCreateError(
                    index: index, message: String(describing: error)
                ))
            } catch {
                errors.append(ReviewTaskBulkCreateError(
                    index: index, message: error.localizedDescription
                ))
            }
        }
        return ReviewTaskBulkCreateResult(created: created, errors: errors)
    }

    private func buildBulkTask(
        item: ReviewTaskBulkItem,
        defaults: ReviewTaskBulkDefaults?,
        sessionId: String,
        index: Int
    ) throws -> ReviewTask {
        let title = nonBlank(item.title) ?? nonBlank(defaults?.title)
            ?? "Bulk-created task \(index + 1)"
        let instructions = nonBlank(item.instructions) ?? nonBlank(defaults?.instructions)
            ?? "Review the attached element and apply the requested change."
        let priority = nonBlank(item.priority) ?? nonBlank(defaults?.priority) ?? "normal"
        let assignee = nonBlank(item.assignee) ?? nonBlank(defaults?.assignee)

        // Reject blank-after-defaults — keeps the partial-success contract honest.
        if nonBlank(item.title) == nil && nonBlank(defaults?.title) == nil
            && item.title != nil {
            throw ReviewTaskStoreError.sqlite("title is blank and no default supplied")
        }

        let now = Date()
        let taskId = FileReviewStore.makeID(prefix: "task")
        let elements: [ReviewTaskElement] = item.elements.map { input in
            ReviewTaskElement(
                id: FileReviewStore.makeID(prefix: "taskel"),
                taskId: taskId,
                snapshotId: input.snapshotId,
                axNodePath: input.axNodePath,
                role: nil,
                label: nil,
                frame: nil,
                commentText: input.commentText
            )
        }
        return ReviewTask(
            id: taskId,
            sessionId: sessionId,
            bundleId: item.bundleId,
            title: title,
            instructions: instructions,
            status: "open",
            priority: priority,
            assignee: assignee,
            contextPath: nil,
            bundleJSONPath: nil,
            bundleMarkdownPath: nil,
            resultSummary: nil,
            verificationSnapshotId: nil,
            createdAt: now,
            updatedAt: now,
            claimedAt: nil,
            completedAt: nil,
            elements: elements,
            events: [
                ReviewTaskEvent(
                    id: FileReviewStore.makeID(prefix: "event"),
                    taskId: taskId,
                    type: "created",
                    actor: assignee,
                    message: "Bulk-created task",
                    metadataJSON: nil,
                    createdAt: now
                )
            ]
        )
    }

    func appendCodeChanges(taskId: String, input: ReviewTaskCodeChangesInput) throws -> ReviewTask {
        try locked {
            _ = try loadTaskUnlocked(id: taskId)
            let now = Date()
            for change in input.changes {
                let truncated = truncateDiff(change.diffText)
                try run(
                    """
                    INSERT INTO review_task_code_changes
                    (id, task_id, path, summary, start_line, end_line,
                     commit_sha, branch, language, diff_text, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        FileReviewStore.makeID(prefix: "cc"),
                        taskId,
                        change.path,
                        change.summary,
                        change.startLine.map(String.init),
                        change.endLine.map(String.init),
                        change.commitSha,
                        change.branch,
                        change.language,
                        truncated,
                        iso(now),
                    ]
                )
            }
            let message = "Recorded \(input.changes.count) code change\(input.changes.count == 1 ? "" : "s")"
            try insertEvent(ReviewTaskEvent(
                id: FileReviewStore.makeID(prefix: "event"),
                taskId: taskId,
                type: "code_changes",
                actor: input.actor,
                message: message,
                metadataJSON: nil,
                createdAt: now
            ))
            try run(
                "UPDATE review_tasks SET updated_at = ? WHERE id = ?",
                [iso(now), taskId]
            )
            return try loadTaskUnlocked(id: taskId)
        }
    }

    func recordVerdicts(taskId: String, verdicts: [Verdict], status: String) throws -> ReviewTask {
        try locked {
            var task = try loadTaskUnlocked(id: taskId)
            task.verdicts = verdicts
            task.status = status
            if ["verified", "failed", "cancelled"].contains(status) {
                task.completedAt = Date()
            }
            task.updatedAt = Date()
            try run(
                """
                UPDATE review_tasks SET verdicts_json = ?, status = ?,
                  updated_at = ?, completed_at = ? WHERE id = ?
                """,
                [jsonString(verdicts), status, iso(task.updatedAt),
                 task.completedAt.map(iso), taskId]
            )
            let passes = verdicts.filter { $0.outcome == .pass }.count
            try insertEvent(ReviewTaskEvent(
                id: FileReviewStore.makeID(prefix: "event"),
                taskId: taskId,
                type: "verdicts:\(status)",
                actor: nil,
                message: "Recorded \(verdicts.count) verdict\(verdicts.count == 1 ? "" : "s") (\(passes) pass)",
                metadataJSON: nil,
                createdAt: Date()
            ))
            return try loadTaskUnlocked(id: taskId)
        }
    }

    private static let maxDiffBytes = 256 * 1024
    private func truncateDiff(_ text: String?) -> String? {
        guard let text else { return nil }
        let data = Data(text.utf8)
        guard data.count > Self.maxDiffBytes else { return text }
        let head = data.prefix(Self.maxDiffBytes)
        let prefix = String(data: head, encoding: .utf8) ?? String(text.prefix(Self.maxDiffBytes))
        return prefix + "\n[…truncated]"
    }

    func addVerification(taskId: String, verification: ReviewTaskVerification) throws -> ReviewTask {
        try locked {
            _ = try loadTaskUnlocked(id: taskId)
            try run(
                """
                INSERT INTO review_verifications
                (id, task_id, before_snapshot_ids_json, after_snapshot_id, status, notes, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    verification.id,
                    verification.taskId,
                    String(data: try encoder.encode(verification.beforeSnapshotIds), encoding: .utf8) ?? "[]",
                    verification.afterSnapshotId,
                    verification.status,
                    verification.notes,
                    iso(verification.createdAt)
                ]
            )
            try insertEvent(ReviewTaskEvent(
                id: FileReviewStore.makeID(prefix: "event"),
                taskId: taskId,
                type: "verification:\(verification.status)",
                actor: nil,
                message: verification.notes ?? "Verification recorded",
                metadataJSON: nil,
                createdAt: Date()
            ))
            return try loadTaskUnlocked(id: taskId)
        }
    }

    private func migrate() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS review_tasks (
              id TEXT PRIMARY KEY,
              session_id TEXT NOT NULL,
              bundle_id TEXT,
              title TEXT NOT NULL,
              instructions TEXT NOT NULL,
              status TEXT NOT NULL,
              priority TEXT NOT NULL,
              assignee TEXT,
              context_path TEXT,
              bundle_json_path TEXT,
              bundle_markdown_path TEXT,
              result_summary TEXT,
              verification_snapshot_id TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              claimed_at TEXT,
              completed_at TEXT,
              criteria_json TEXT,
              verdicts_json TEXT
            )
            """)
        // Tasks created before ADR-0002 predate these columns; add them
        // in place so existing queues keep loading.
        try addColumnIfMissing(table: "review_tasks", column: "criteria_json", type: "TEXT")
        try addColumnIfMissing(table: "review_tasks", column: "verdicts_json", type: "TEXT")
        try exec("""
            CREATE TABLE IF NOT EXISTS review_task_elements (
              id TEXT PRIMARY KEY,
              task_id TEXT NOT NULL,
              snapshot_id TEXT NOT NULL,
              ax_node_path TEXT NOT NULL,
              role TEXT,
              label TEXT,
              frame_json TEXT,
              comment_text TEXT,
              FOREIGN KEY(task_id) REFERENCES review_tasks(id) ON DELETE CASCADE
            )
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS review_task_events (
              id TEXT PRIMARY KEY,
              task_id TEXT NOT NULL,
              type TEXT NOT NULL,
              actor TEXT,
              message TEXT NOT NULL,
              metadata_json TEXT,
              created_at TEXT NOT NULL,
              FOREIGN KEY(task_id) REFERENCES review_tasks(id) ON DELETE CASCADE
            )
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS review_verifications (
              id TEXT PRIMARY KEY,
              task_id TEXT NOT NULL,
              before_snapshot_ids_json TEXT NOT NULL,
              after_snapshot_id TEXT,
              status TEXT NOT NULL,
              notes TEXT,
              created_at TEXT NOT NULL,
              FOREIGN KEY(task_id) REFERENCES review_tasks(id) ON DELETE CASCADE
            )
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS review_task_code_changes (
              id TEXT PRIMARY KEY,
              task_id TEXT NOT NULL,
              path TEXT NOT NULL,
              summary TEXT,
              start_line TEXT,
              end_line TEXT,
              commit_sha TEXT,
              branch TEXT,
              language TEXT,
              diff_text TEXT,
              created_at TEXT NOT NULL,
              FOREIGN KEY(task_id) REFERENCES review_tasks(id) ON DELETE CASCADE
            )
            """)
        try exec("CREATE INDEX IF NOT EXISTS idx_review_tasks_status ON review_tasks(status, created_at)")
        try exec("CREATE INDEX IF NOT EXISTS idx_review_tasks_session ON review_tasks(session_id, updated_at)")
        try exec("CREATE INDEX IF NOT EXISTS idx_code_changes_task ON review_task_code_changes(task_id, created_at)")
    }

    /// Idempotent `ALTER TABLE … ADD COLUMN` — checks `PRAGMA table_info`
    /// first so re-running `migrate()` on an already-upgraded DB is a no-op.
    private func addColumnIfMissing(table: String, column: String, type: String) throws {
        let existing = try query("PRAGMA table_info(\(table))", []) { stmt in
            text(stmt, 1)   // column 1 of table_info is the column name
        }
        guard !existing.contains(column) else { return }
        try exec("ALTER TABLE \(table) ADD COLUMN \(column) \(type)")
    }

    private func insertTask(_ task: ReviewTask) throws {
        try run(
            """
            INSERT INTO review_tasks
            (id, session_id, bundle_id, title, instructions, status, priority, assignee,
             context_path, bundle_json_path, bundle_markdown_path, result_summary,
             verification_snapshot_id, created_at, updated_at, claimed_at, completed_at,
             criteria_json, verdicts_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                task.id, task.sessionId, task.bundleId, task.title, task.instructions,
                task.status, task.priority, task.assignee, task.contextPath,
                task.bundleJSONPath, task.bundleMarkdownPath, task.resultSummary,
                task.verificationSnapshotId, iso(task.createdAt), iso(task.updatedAt),
                task.claimedAt.map(iso), task.completedAt.map(iso),
                jsonString(task.criteria), jsonString(task.verdicts)
            ]
        )
    }

    private func updateTaskRow(_ task: ReviewTask) throws {
        try run(
            """
            UPDATE review_tasks SET
              title = ?, instructions = ?, status = ?, priority = ?, assignee = ?,
              context_path = ?, result_summary = ?, verification_snapshot_id = ?,
              updated_at = ?, claimed_at = ?, completed_at = ?
            WHERE id = ?
            """,
            [
                task.title, task.instructions, task.status, task.priority, task.assignee,
                task.contextPath, task.resultSummary, task.verificationSnapshotId,
                iso(task.updatedAt), task.claimedAt.map(iso), task.completedAt.map(iso), task.id
            ]
        )
    }

    private func insertElement(_ element: ReviewTaskElement) throws {
        let frameJSON = try element.frame.map { String(data: try encoder.encode($0), encoding: .utf8) ?? "{}" }
        try run(
            """
            INSERT INTO review_task_elements
            (id, task_id, snapshot_id, ax_node_path, role, label, frame_json, comment_text)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                element.id, element.taskId, element.snapshotId, element.axNodePath,
                element.role, element.label, frameJSON, element.commentText
            ]
        )
    }

    private func insertEvent(_ event: ReviewTaskEvent) throws {
        try run(
            """
            INSERT INTO review_task_events
            (id, task_id, type, actor, message, metadata_json, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [
                event.id, event.taskId, event.type, event.actor,
                event.message, event.metadataJSON, iso(event.createdAt)
            ]
        )
    }

    private func claimTaskUnlocked(id: String, agentId: String) throws -> ReviewTask {
        var task = try loadTaskUnlocked(id: id)
        if task.status == "open" {
            task.status = "claimed"
            task.assignee = agentId
            task.claimedAt = Date()
            task.updatedAt = task.claimedAt ?? Date()
            try updateTaskRow(task)
            try insertEvent(ReviewTaskEvent(
                id: FileReviewStore.makeID(prefix: "event"),
                taskId: id,
                type: "claimed",
                actor: agentId,
                message: "Task claimed",
                metadataJSON: nil,
                createdAt: Date()
            ))
        }
        return try loadTaskUnlocked(id: id)
    }

    private func loadTaskUnlocked(id: String) throws -> ReviewTask {
        guard let row = try queryTaskRows("SELECT * FROM review_tasks WHERE id = ?", [id]).first else {
            throw ReviewTaskStoreError.notFound(id)
        }
        return try hydrate(row)
    }

    private func hydrate(_ row: TaskRow) throws -> ReviewTask {
        let elements = try queryElements(taskId: row.id)
        let events = try queryEvents(taskId: row.id)
        let codeChanges = try queryCodeChanges(taskId: row.id)
        return ReviewTask(
            id: row.id,
            sessionId: row.sessionId,
            bundleId: row.bundleId,
            title: row.title,
            instructions: row.instructions,
            status: row.status,
            priority: row.priority,
            assignee: row.assignee,
            contextPath: row.contextPath,
            bundleJSONPath: row.bundleJSONPath,
            bundleMarkdownPath: row.bundleMarkdownPath,
            resultSummary: row.resultSummary,
            verificationSnapshotId: row.verificationSnapshotId,
            createdAt: date(row.createdAt),
            updatedAt: date(row.updatedAt),
            claimedAt: row.claimedAt.map(date),
            completedAt: row.completedAt.map(date),
            elements: elements,
            events: events,
            codeChanges: codeChanges,
            criteria: decodeJSON(row.criteriaJSON, as: [AcceptanceCriterion].self),
            verdicts: decodeJSON(row.verdictsJSON, as: [Verdict].self)
        )
    }

    private func queryCodeChanges(taskId: String) throws -> [ReviewTaskCodeChange] {
        try query(
            "SELECT id, task_id, path, summary, start_line, end_line, commit_sha, branch, language, diff_text, created_at FROM review_task_code_changes WHERE task_id = ? ORDER BY created_at ASC, rowid ASC",
            [taskId]
        ) { stmt in
            ReviewTaskCodeChange(
                id: text(stmt, 0) ?? "",
                taskId: text(stmt, 1) ?? "",
                path: text(stmt, 2) ?? "",
                summary: text(stmt, 3),
                startLine: text(stmt, 4).flatMap(Int.init),
                endLine: text(stmt, 5).flatMap(Int.init),
                commitSha: text(stmt, 6),
                branch: text(stmt, 7),
                language: text(stmt, 8),
                diffText: text(stmt, 9),
                createdAt: date(text(stmt, 10) ?? "")
            )
        }
    }

    private func queryElements(taskId: String) throws -> [ReviewTaskElement] {
        try query("SELECT * FROM review_task_elements WHERE task_id = ? ORDER BY rowid", [taskId]) { stmt in
            let frameText = text(stmt, 6)
            let frame = frameText.flatMap { try? decoder.decode(Rect.self, from: Data($0.utf8)) }
            return ReviewTaskElement(
                id: text(stmt, 0) ?? "",
                taskId: text(stmt, 1) ?? "",
                snapshotId: text(stmt, 2) ?? "",
                axNodePath: text(stmt, 3) ?? "",
                role: text(stmt, 4),
                label: text(stmt, 5),
                frame: frame,
                commentText: text(stmt, 7)
            )
        }
    }

    private func queryEvents(taskId: String) throws -> [ReviewTaskEvent] {
        try query("SELECT * FROM review_task_events WHERE task_id = ? ORDER BY created_at ASC", [taskId]) { stmt in
            ReviewTaskEvent(
                id: text(stmt, 0) ?? "",
                taskId: text(stmt, 1) ?? "",
                type: text(stmt, 2) ?? "",
                actor: text(stmt, 3),
                message: text(stmt, 4) ?? "",
                metadataJSON: text(stmt, 5),
                createdAt: date(text(stmt, 6) ?? "")
            )
        }
    }

    private func queryTaskRows(_ sql: String, _ args: [String?]) throws -> [TaskRow] {
        try query(sql, args) { stmt in
            TaskRow(
                id: text(stmt, 0) ?? "",
                sessionId: text(stmt, 1) ?? "",
                bundleId: text(stmt, 2),
                title: text(stmt, 3) ?? "",
                instructions: text(stmt, 4) ?? "",
                status: text(stmt, 5) ?? "",
                priority: text(stmt, 6) ?? "",
                assignee: text(stmt, 7),
                contextPath: text(stmt, 8),
                bundleJSONPath: text(stmt, 9),
                bundleMarkdownPath: text(stmt, 10),
                resultSummary: text(stmt, 11),
                verificationSnapshotId: text(stmt, 12),
                createdAt: text(stmt, 13) ?? "",
                updatedAt: text(stmt, 14) ?? "",
                claimedAt: text(stmt, 15),
                completedAt: text(stmt, 16),
                criteriaJSON: text(stmt, 17),
                verdictsJSON: text(stmt, 18)
            )
        }
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw ReviewTaskStoreError.sqlite(lastError)
        }
    }

    private func run(_ sql: String, _ args: [Any?]) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ReviewTaskStoreError.sqlite(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        try bind(args, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ReviewTaskStoreError.sqlite(lastError)
        }
    }

    private func query<T>(_ sql: String, _ args: [Any?], map: (OpaquePointer?) throws -> T) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ReviewTaskStoreError.sqlite(lastError)
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
                sqlite3_bind_text(stmt, slot, value, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_text(stmt, slot, String(describing: value!), -1, SQLITE_TRANSIENT)
            }
        }
    }

    private var lastError: String {
        String(cString: sqlite3_errmsg(db))
    }

    /// Encode a value-type array to a JSON column string; `[]` on failure
    /// so a write never silently drops to NULL on an empty/encodable list.
    private func jsonString<T: Encodable>(_ value: [T]) -> String {
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else { return "[]" }
        return string
    }

    /// Decode a JSON column back to its array; nil/blank/garbage → `[]`.
    private func decodeJSON<T: Decodable>(_ text: String?, as type: [T].Type) -> [T] {
        guard let text, let data = text.data(using: .utf8),
              let value = try? decoder.decode([T].self, from: data) else { return [] }
        return value
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

private struct TaskRow {
    let id: String
    let sessionId: String
    let bundleId: String?
    let title: String
    let instructions: String
    let status: String
    let priority: String
    let assignee: String?
    let contextPath: String?
    let bundleJSONPath: String?
    let bundleMarkdownPath: String?
    let resultSummary: String?
    let verificationSnapshotId: String?
    let createdAt: String
    let updatedAt: String
    let claimedAt: String?
    let completedAt: String?
    let criteriaJSON: String?
    let verdictsJSON: String?
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func nonBlank(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
