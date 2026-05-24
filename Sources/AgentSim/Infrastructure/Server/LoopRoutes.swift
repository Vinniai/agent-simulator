import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// Fork-only HTTP surface for the Agentic Feedback Loop (ADR-0001).
///
/// Loop-specific routes live here, not in `Server`'s route table, so that
/// absorbing an upstream change to `Server` stays a clean cherry-pick — the
/// upstream-tracking file never grows loop logic that would conflict. The
/// file is deliberately self-contained: it builds its own JSON `Response`s
/// rather than reaching into `Server`'s private helpers, so the boundary is
/// a one-line `LoopRoutes.register(...)` call and nothing more.
///
/// First occupant: criteria verification (ADR-0002).
enum LoopRoutes {
    enum VerifyError: Error, Equatable {
        case noVerificationSnapshot
        case snapshotNotFound(String)
        case unreadableArtifact(String)
    }

    /// Snapshot-default criteria verification: resolve the task's
    /// verification snapshot, decode that snapshot's AX artifact (the
    /// `axPath` file, which is `AXNode.json`), and run ``VerifyTask``
    /// against it. Pure of any simulator, so it is reproducible and
    /// replayable. The snapshot is looked up in the task's own session.
    static func verifyFromSnapshot(
        taskId: String,
        taskStore: any ReviewTaskStore,
        reviewStore: any ReviewStore
    ) throws -> ReviewTask {
        let task = try taskStore.loadTask(id: taskId)
        guard let snapshotId = task.verificationSnapshotId else {
            throw VerifyError.noVerificationSnapshot
        }
        let session = try reviewStore.loadSession(id: task.sessionId)
        guard let snapshot = session.snapshots.first(where: { $0.id == snapshotId }) else {
            throw VerifyError.snapshotNotFound(snapshotId)
        }
        let data = try reviewStore.readArtifact(
            sessionId: task.sessionId, relativePath: snapshot.axPath)
        guard let tree = AXNode.from(json: data) else {
            throw VerifyError.unreadableArtifact(snapshot.axPath)
        }
        return try VerifyTask.run(store: taskStore, taskId: taskId, tree: tree)
    }

    /// Live criteria verification: run ``VerifyTask`` against a freshly
    /// captured `describe-ui` tree. Integration-only (needs a booted sim);
    /// the verdict logic itself is the same engine as the snapshot path.
    static func verifyLive(
        taskId: String,
        tree: AXNode,
        taskStore: any ReviewTaskStore
    ) throws -> ReviewTask {
        try VerifyTask.run(store: taskStore, taskId: taskId, tree: tree)
    }

    /// Register the loop's routes onto the shared router. Today just
    /// `POST /review-tasks/:id/verify-criteria`; `?live=1&udid=…` switches
    /// from the captured snapshot to a fresh describe-ui tree.
    static func register(
        on router: Router<BasicWebSocketRequestContext>,
        taskStore: any ReviewTaskStore,
        reviewStore: any ReviewStore,
        simulators: any Simulators
    ) {
        router.post("/review-tasks/:id/verify-criteria") { request, _ in
            let id = idParam(request)
            let live = ["1", "true"].contains(
                String(request.uri.queryParameters.get("live") ?? ""))
            do {
                let task: ReviewTask
                if live {
                    let udid = String(request.uri.queryParameters.get("udid") ?? "")
                    guard !udid.isEmpty, let sim = simulators.find(udid: udid) else {
                        return error("live verify needs a known ?udid=", status: .badRequest)
                    }
                    guard let tree = try sim.accessibility().describeAll() else {
                        return error("no accessibility tree on \(udid)", status: .badRequest)
                    }
                    task = try verifyLive(taskId: id, tree: tree, taskStore: taskStore)
                } else {
                    task = try verifyFromSnapshot(
                        taskId: id, taskStore: taskStore, reviewStore: reviewStore)
                }
                return json(try encoder.encode(task))
            } catch ReviewTaskStoreError.notFound {
                return error("unknown task: \(id)", status: .notFound)
            } catch let e as VerifyError {
                return error(String(describing: e), status: .badRequest)
            } catch let e {
                return error(String(describing: e), status: .internalServerError)
            }
        }
    }

    // MARK: - self-contained response building (no Server internals)

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static func json(_ data: Data, status: HTTPResponse.Status = .ok) -> Response {
        Response(
            status: status,
            headers: [.contentType: "application/json", .cacheControl: "no-cache"],
            body: .init(byteBuffer: ByteBuffer(data: data)))
    }

    private static func error(_ message: String, status: HTTPResponse.Status) -> Response {
        let escaped = message.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(string: "{\"ok\":false,\"error\":\"\(escaped)\"}")))
    }

    /// `/review-tasks/:id/…` → the `:id` path segment, percent-decoded.
    private static func idParam(_ request: Request) -> String {
        let parts = request.uri.path.split(separator: "/")
        guard parts.count >= 2 else { return "" }
        return String(parts[1]).removingPercentEncoding ?? ""
    }
}
