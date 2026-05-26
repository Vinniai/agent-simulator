import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore
@_spi(WSInternal) import WSCore

/// Standalone HTTP + WebSocket server for `agent-sim serve`.
///
/// The server is **dumb**: it serves static UI files unchanged and
/// projects domain values to JSON / PNG. No HTML rewriting, no
/// template extraction, no script inlining. Anything UI-shaped lives
/// in `Resources/Web/` and is the front-end's problem.
///
/// Canonical routes (no `/api/` prefix; UDID always in path; format
/// distinguished by file extension):
///
///   GET  /                                  → 302 → /simulators
///   GET  /simulators                        → sim.html
///   GET  /simulators.json                   → list JSON
///   GET  /simulators/:udid                  → sim.html  (stream)
///   POST /simulators/:udid/boot             → simulator.boot()
///   POST /simulators/:udid/shutdown         → simulator.shutdown()
///   GET  /simulators/:udid/chrome.json      → chrome layout JSON
///   GET  /simulators/:udid/bezel.png        → composite PNG
///   POST /simulators/:udid/input            → gesture     (TODO)
///   GET  /simulators/:udid/screenshot.jpg   → JPEG (?quality=&scale=)
///   WS   /simulators/:udid/stream?format=   → frames      (TODO)
///   GET  /<file>.{html,js,css}              → static UI asset
///
/// Static UI siblings live at the *root* (e.g. `GET /sim-list.js`)
/// so the page at `/simulators` resolves `<script src="sim-list.js">`
/// to a sibling — no prefix juggling, no conflict with the
/// `/simulators/:udid` resource tree (UDIDs don't end in `.js`).
struct Server: Sendable {
    let simulators: any Simulators
    let chromes: any Chromes
    let reviewStore: any ReviewStore
    let reviewTaskStore: any ReviewTaskStore
    /// Session-less notes queue — messages left from the mobile sim
    /// view, promotable into a review task.
    let notes: any Notes
    /// Local Metro probe used by `/triangulate` to map a screen point
    /// to a project root. `HostMetro` defaults; tests inject a fake.
    let metro: any Metro
    let host: String
    let port: Int
    /// Extra hostnames trusted in addition to the bind host — e.g. a
    /// Tailscale MagicDNS name so the UI is reachable over the tailnet
    /// while still bound to loopback. Empty = loopback-only (default).
    let trustedHosts: Set<String>
    /// Hostnames discovered at runtime — a quick tunnel's public name
    /// isn't known until the child prints it, so `serve --tunnel` feeds
    /// it in through this live provider instead of the fixed allowlist.
    /// Consulted per-request and unioned with `trustedHosts`.
    let dynamicTrustedHosts: @Sendable () -> Set<String>

    init(
        simulators: any Simulators,
        chromes: any Chromes,
        reviewStore: any ReviewStore = FileReviewStore(),
        reviewTaskStore: any ReviewTaskStore = SQLiteReviewTaskStore(),
        notes: any Notes = SQLiteNotes(),
        metro: any Metro = HostMetro(),
        host: String = "127.0.0.1",
        port: Int = 8421,
        trustedHosts: Set<String> = [],
        dynamicTrustedHosts: @escaping @Sendable () -> Set<String> = { [] }
    ) {
        self.simulators = simulators
        self.chromes = chromes
        self.reviewStore = reviewStore
        self.reviewTaskStore = reviewTaskStore
        self.notes = notes
        self.metro = metro
        self.host = host
        self.port = port
        self.trustedHosts = trustedHosts
        self.dynamicTrustedHosts = dynamicTrustedHosts
    }

    func run() async throws {
        let router = makeRouter()
        log("listening on http://\(host):\(port)/simulators")

        let app = Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: .init(address: .hostname(host, port: port))
        )
        try await app.runService()
    }

    /// Exposed for tests — build the router without binding a port.
    func makeRouter() -> Router<BasicWebSocketRequestContext> {
        let router = Router(context: BasicWebSocketRequestContext.self)
        registerRoutes(on: router)
        return router
    }

    // MARK: - routes

    private func registerRoutes(on router: Router<BasicWebSocketRequestContext>) {
        // Fork-only loop surface (ADR-0001) lives in LoopRoutes, off the
        // upstream-tracking route table, so absorbing upstream stays clean.
        LoopRoutes.register(
            on: router, taskStore: reviewTaskStore,
            reviewStore: reviewStore, simulators: simulators)
        let bindHost = self.host
        let bindPort = self.port
        let staticTrusted = self.trustedHosts
        let dynamicTrusted = self.dynamicTrustedHosts
        let currentTrusted: @Sendable () -> Set<String> = {
            Self.effectiveTrustedHosts(static: staticTrusted, dynamic: dynamicTrusted())
        }
        let rejectUntrustedBrowser: @Sendable (Request) -> Response? = { request in
            Self.rejectUntrustedBrowserRequest(
                request, bindHost: bindHost, bindPort: bindPort, trustedHosts: currentTrusted()
            )
        }
        let trustedWebSocketUpgrade:
            @Sendable (Request, BasicWebSocketRequestContext) async throws -> RouterShouldUpgrade = {
                request, _ in
                Self.isTrustedBrowserRequest(
                    request, bindHost: bindHost, bindPort: bindPort, trustedHosts: currentTrusted()
                ) ? .upgrade([:]) : .dontUpgrade
            }

        // Health / version probe. Used by `agent-sim doctor` to detect
        // a drift between the local CLI binary and the running server,
        // and by external tooling (CI, watchdogs) to confirm reachability
        // without needing to parse a richer payload.
        router.get("/version") { _, _ in Self.versionJSON() }

        // List page (HTML + sibling assets).
        router.get("/") { _, _ in Self.redirect(to: "/simulators") }
        router.get("/simulators") { r, _ in Self.staticAsset(Self.shellAsset(forPath: r.uri.path)) }
        router.get("/simulators.json") { [simulators] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            return Self.listJSON(simulators)
        }

        // Stream page — same sim.html, JS routes the inner view based on URL.
        router.get("/simulators/:udid") { r, _ in Self.staticAsset(Self.shellAsset(forPath: r.uri.path)) }

        // Mobile single-sim entry — thumb-friendly focus view, same shell;
        // the JS activation gate also accepts the `/m/<udid>` prefix.
        router.get("/m/:udid")  { r, _ in Self.staticAsset(Self.shellAsset(forPath: r.uri.path)) }
        router.head("/m/:udid") { r, _ in Self.staticAsset(Self.shellAsset(forPath: r.uri.path)) }

        // Simulator actions.
        router.post("/simulators/:udid/boot")     { [simulators] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            return Self.lifecycle(udid: Self.udidParam(r), simulators: simulators) { try $0.boot() }
        }
        router.post("/simulators/:udid/shutdown") { [simulators] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            return Self.lifecycle(udid: Self.udidParam(r), simulators: simulators) { try $0.shutdown() }
        }
        // Orientation — `?value=portrait|landscape-left|landscape-right|portrait-upside-down`.
        // Routes through `simulator.orientation().set(...)` which fires
        // a GSEvent over `PurpleWorkspacePort`. Pure parse + dispatch
        // logic lives in `Server.applyOrientation` for unit testing.
        router.post("/simulators/:udid/orientation") { [simulators] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let value = r.uri.queryParameters.get("value") ?? ""
            switch Self.applyOrientation(
                udid: Self.udidParam(r), value: value, simulators: simulators
            ) {
            case .ok:
                return jsonOK
            case .invalidValue:
                return errorJSON(
                    "value must be one of portrait, landscape-left, landscape-right, portrait-upside-down",
                    status: .badRequest
                )
            case .unknownDevice:
                return errorJSON("unknown udid: \(Self.udidParam(r))", status: .notFound)
            case .dispatchFailed:
                return errorJSON(
                    "orientation change failed (PurpleWorkspacePort unreachable?)",
                    status: .internalServerError
                )
            }
        }

        // Chrome / bezel — DeviceKit-sourced layout + rasterized PNG.
        router.get("/simulators/:udid/chrome.json") { [simulators, chromes] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            return Self.chromeJSON(udid: Self.udidParam(r), simulators: simulators, chromes: chromes)
        }
        router.get("/simulators/:udid/bezel.png") { [simulators, chromes] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            // ?buttons=false → bare device body (no buttons baked in).
            // The actionable-bezel front end layers per-button images on
            // top via the /chrome-button/<name>.png route below.
            // Default (true) preserves today's merged composite.
            let withButtons = r.uri.queryParameters.get("buttons")
                .map { $0.lowercased() != "false" } ?? true
            return Self.bezelPNG(
                udid: Self.udidParam(r),
                simulators: simulators,
                chromes: chromes,
                withButtons: withButtons
            )
        }
        // Per-button rasterized PNG — feeds the actionable-bezel UI.
        // `:file` is the last URL segment, typically `<name>.png`
        // matching a `ChromeButton.name` in `chrome.json` (e.g.
        // `powerButton.png`, `actionButton.png`, `volumeUp.png`).
        // Registered before the catch-all `/:file` so the longer
        // template wins.
        //
        // UDID extraction here uses positional indexing on the path
        // (`parts[1]`) instead of `udidParam` — that helper assumes
        // a 3-segment path and grabs the second-to-last component,
        // which breaks for this 4-segment template.
        router.get("/simulators/:udid/chrome-button/:file") { [simulators, chromes] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let parts = r.uri.path.split(separator: "/")
            let udid = parts.count >= 4
                ? String(parts[1]).removingPercentEncoding ?? ""
                : ""
            let last = String(parts.last ?? "")
                .removingPercentEncoding ?? ""
            return Self.chromeButtonPNG(
                udid: udid,
                buttonFile: last,
                simulators: simulators,
                chromes: chromes
            )
        }

        // One-shot JPEG of the current framebuffer. Spins up Screen,
        // awaits one IOSurface, encodes, and tears down — `?quality=`
        // and `?scale=` mirror the WS stream knobs for parity.
        router.get("/simulators/:udid/screenshot.jpg") { [simulators] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            return await Self.screenshotJPEG(
                udid: Self.udidParam(r),
                quality: r.uri.queryParameters.get("quality").flatMap(Double.init) ?? 0.85,
                scale: r.uri.queryParameters.get("scale").flatMap(Int.init) ?? 1,
                simulators: simulators
            )
        }

        // Device-farm UI — multi-device dashboard. The HTML at /farm
        // is a thin shell that loads its own component scripts from
        // the `farm/` subfolder; sibling assets (CSS + per-component
        // JS) resolve against `/farm/<file>`. Registered before the
        // catch-all `/:file` so `/farm` doesn't get hijacked.
        router.get("/farm")  { r, _ in Self.staticAsset(Self.shellAsset(forPath: r.uri.path)) }
        router.head("/farm") { r, _ in Self.staticAsset(Self.shellAsset(forPath: r.uri.path)) }
        router.get("/m")     { r, _ in Self.staticAsset(Self.shellAsset(forPath: r.uri.path)) }
        router.head("/m")    { r, _ in Self.staticAsset(Self.shellAsset(forPath: r.uri.path)) }
        router.get("/farm/:file") { r, _ in
            let name = String(r.uri.path.split(separator: "/").last ?? "")
                .removingPercentEncoding ?? ""
            return Self.staticAsset("farm/\(name)")
        }
        router.head("/farm/:file") { r, _ in
            let name = String(r.uri.path.split(separator: "/").last ?? "")
                .removingPercentEncoding ?? ""
            return Self.staticAsset("farm/\(name)")
        }

        // Review map — durable point-in-time screenshots + AX trees
        // arranged as a screen graph. The live simulator pages use
        // these endpoints when Review Mode is enabled; /reviews/:id is
        // the persistent viewer for markup and evidence bundles.
        router.get("/reviews") { _, _ in Self.staticAsset("review.html") }
        router.get("/reviews/:id") { _, _ in Self.staticAsset("review.html") }
        router.get("/reviews.json") { [reviewStore] _, _ in
            Self.reviewListJSON(store: reviewStore)
        }
        router.post("/reviews") { [reviewStore] r, _ in
            await Self.createReview(request: r, store: reviewStore)
        }
        router.get("/reviews/:id/manifest.json") { [reviewStore] r, _ in
            Self.reviewManifestJSON(id: Self.reviewIdParam(r), store: reviewStore)
        }
        router.post("/reviews/:id/capture") { [simulators, reviewStore] r, _ in
            await Self.captureReview(
                id: Self.reviewIdParam(r),
                request: r,
                simulators: simulators,
                store: reviewStore
            )
        }
        router.post("/reviews/:id/snapshots/import") { [reviewStore] r, _ in
            await Self.importReviewSnapshot(
                id: Self.reviewIdParam(r),
                request: r,
                store: reviewStore
            )
        }
        router.post("/reviews/:id/edge") { [reviewStore] r, _ in
            await Self.addReviewEdge(
                id: Self.reviewIdParam(r),
                request: r,
                store: reviewStore
            )
        }
        router.post("/reviews/:id/comments") { [reviewStore] r, _ in
            await Self.addReviewComment(
                id: Self.reviewIdParam(r),
                request: r,
                store: reviewStore
            )
        }
        router.post("/reviews/:id/bundles") { [reviewStore] r, _ in
            await Self.createReviewBundle(
                id: Self.reviewIdParam(r),
                request: r,
                store: reviewStore
            )
        }
        router.post("/reviews/:id/tasks") { [reviewStore, reviewTaskStore] r, _ in
            await Self.createReviewTask(
                id: Self.reviewIdParam(r),
                request: r,
                store: reviewStore,
                taskStore: reviewTaskStore
            )
        }
        router.post("/reviews/:id/tasks/bulk") { [reviewTaskStore] r, _ in
            await Self.bulkCreateReviewTasks(
                id: Self.reviewIdParam(r),
                request: r,
                taskStore: reviewTaskStore
            )
        }
        router.post("/reviews/:id/flows") { [reviewStore] r, _ in
            await Self.createReviewFlow(
                id: Self.reviewIdParam(r),
                request: r,
                store: reviewStore
            )
        }
        router.get("/reviews/:id/flows.json") { [reviewStore] r, _ in
            Self.listReviewFlows(id: Self.reviewIdParam(r), store: reviewStore)
        }
        router.post("/reviews/:id/flows/:flowId/replay") { [reviewStore, simulators] r, _ in
            await Self.replayReviewFlow(
                id: Self.reviewIdParam(r),
                flowId: Self.flowIdParam(r),
                request: r,
                store: reviewStore,
                simulators: simulators
            )
        }
        router.post("/reviews/:id/recordings") { [reviewStore] r, _ in
            await Self.uploadReviewRecording(
                id: Self.reviewIdParam(r),
                request: r,
                store: reviewStore
            )
        }
        router.get("/reviews/:id/recordings.json") { [reviewStore] r, _ in
            Self.listReviewRecordings(id: Self.reviewIdParam(r), store: reviewStore)
        }
        router.post("/reviews/source-search") { r, _ in
            await Self.reviewSourceSearch(request: r)
        }
        // Map a screen point → AX node + workspace root + (Phase B/C)
        // source candidates. Mobile / desktop inspectors call this when
        // attaching a comment so the review task can pin the element
        // back to a source file as the JSX scanner / fiber lookup land.
        router.post("/triangulate") { [simulators, metro] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            do {
                let input = try await decodeJSON(TriangulateInput.self, from: r)
                guard let json = await Self.triangulateJSONString(
                    input: input, simulators: simulators, metro: metro
                ) else {
                    return errorJSON("unknown udid: \(input.udid)", status: .notFound)
                }
                return jsonResponse(Data(json.utf8))
            } catch {
                return errorJSON(String(describing: error), status: .badRequest)
            }
        }
        router.get("/review-tasks.json") { [reviewTaskStore] r, _ in
            Self.reviewTaskListJSON(
                sessionId: r.uri.queryParameters.get("sessionId"),
                status: r.uri.queryParameters.get("status"),
                taskStore: reviewTaskStore
            )
        }
        router.post("/notes") { [notes] r, _ in
            do {
                let input = try await decodeJSON(NoteCreateInput.self, from: r)
                guard let json = Self.createdNoteJSONString(input, store: notes) else {
                    return errorJSON("empty or rejected note", status: .badRequest)
                }
                return jsonResponse(Data(json.utf8))
            } catch {
                return errorJSON(String(describing: error), status: .badRequest)
            }
        }
        router.get("/notes.json") { [notes] _, _ in
            guard let json = Self.notesInboxJSONString(store: notes) else {
                return errorJSON("notes unavailable", status: .internalServerError)
            }
            return jsonResponse(Data(json.utf8))
        }
        router.post("/notes/:id/promote") { [notes, reviewTaskStore] r, _ in
            guard let json = Self.promoteNoteJSONString(
                id: Self.taskIdParam(r), notes: notes, taskStore: reviewTaskStore
            ) else {
                return errorJSON("unknown note", status: .notFound)
            }
            return jsonResponse(Data(json.utf8))
        }
        router.get("/review-task/:id.json") { [reviewTaskStore] r, _ in
            Self.reviewTaskJSON(id: Self.trailingIDParam(r), taskStore: reviewTaskStore)
        }
        router.post("/review-tasks/:id/claim") { [reviewTaskStore] r, _ in
            await Self.claimReviewTask(
                id: Self.taskIdParam(r),
                request: r,
                taskStore: reviewTaskStore
            )
        }
        router.post("/review-tasks/:id/status") { [reviewTaskStore, reviewStore] r, _ in
            await Self.updateReviewTask(
                id: Self.taskIdParam(r),
                request: r,
                taskStore: reviewTaskStore,
                reviewStore: reviewStore
            )
        }
        router.post("/review-tasks/:id/events") { [reviewTaskStore] r, _ in
            await Self.appendReviewTaskEvent(
                id: Self.taskIdParam(r),
                request: r,
                taskStore: reviewTaskStore
            )
        }
        router.post("/review-tasks/:id/verify") { [reviewTaskStore] r, _ in
            await Self.verifyReviewTask(
                id: Self.taskIdParam(r),
                request: r,
                taskStore: reviewTaskStore
            )
        }
        router.post("/agent/tasks/next") { [reviewTaskStore] r, _ in
            await Self.claimNextReviewTask(request: r, taskStore: reviewTaskStore)
        }
        router.post("/agent/tasks/:id/result") { [reviewTaskStore, reviewStore] r, _ in
            await Self.updateReviewTask(
                id: Self.agentTaskIdParam(r),
                request: r,
                taskStore: reviewTaskStore,
                reviewStore: reviewStore
            )
        }
        router.post("/agent/tasks/:id/events") { [reviewTaskStore] r, _ in
            await Self.appendReviewTaskEvent(
                id: Self.agentTaskIdParam(r),
                request: r,
                taskStore: reviewTaskStore
            )
        }
        router.post("/agent/tasks/:id/code-changes") { [reviewTaskStore] r, _ in
            await Self.appendReviewTaskCodeChanges(
                id: Self.agentTaskIdParam(r),
                request: r,
                taskStore: reviewTaskStore
            )
        }
        router.post("/review-tasks/:id/code-changes") { [reviewTaskStore] r, _ in
            await Self.appendReviewTaskCodeChanges(
                id: Self.taskIdParam(r),
                request: r,
                taskStore: reviewTaskStore
            )
        }
        router.ws("/review-tasks/stream") { [reviewTaskStore] inbound, outbound, context in
            await Self.reviewTasksWS(
                sessionId: context.request.uri.queryParameters.get("sessionId"),
                status: context.request.uri.queryParameters.get("status"),
                taskStore: reviewTaskStore,
                inbound: inbound,
                outbound: outbound
            )
        }
        // Session-less notes inbox, pushed live. Same store the
        // `notes watch` CLI polls and the `/m/:udid` composer writes
        // to — the WS just diff-pushes the snapshot so a phone drawer
        // updates without a 4 s poll. Read-only upstream: a client
        // sends `{"type":"stop"}` (or closes) to end; writes still go
        // through `POST /notes`.
        router.ws("/notes/stream") { [notes] inbound, outbound, context in
            await Self.notesWS(
                status: context.request.uri.queryParameters.get("status"),
                store: notes,
                inbound: inbound,
                outbound: outbound
            )
        }
        router.get("/reviews/:id/artifact") { [reviewStore] r, _ in
            Self.reviewArtifact(
                id: Self.reviewIdParam(r),
                path: r.uri.queryParameters.get("path") ?? "",
                store: reviewStore
            )
        }

        // Live stream — encoded frames downstream as binary; upstream
        // text JSON carries everything else: gesture input + runtime
        // control (set_bitrate / set_fps / set_scale / force_idr /
        // snapshot). One bidirectional channel per session means no
        // POST /event side-route, no UDID-keyed registry — the WS
        // closure already owns the live stream + sim handles.
        router.ws(
            "/simulators/:udid/stream",
            shouldUpgrade: trustedWebSocketUpgrade
        ) { [simulators] inbound, outbound, context in
            await Self.streamWS(
                udid: Self.udidParam(context.request),
                format: context.request.uri.queryParameters.get("format")
                    .flatMap { StreamFormat(rawValue: $0) } ?? .mjpeg,
                simulators: simulators,
                inbound: inbound,
                outbound: outbound
            )
        }

        // Live unified-log feed — dedicated socket so logs don't
        // share lifetime / backpressure with the frame stream.
        // Filter is fixed at connect time (query string); restart
        // the socket to change the filter. Closing the socket from
        // the client tears down the spawned `log` child.
        registerLogsRoute(on: router)

        // Static UI siblings — JS / HTML / CSS files in Resources/Web/
        // accessed by name. Path component is the bare filename.
        router.get("/:file") { r, _ in
            let name = String(r.uri.path.split(separator: "/").last ?? "")
                .removingPercentEncoding ?? ""
            return Self.staticAsset(name)
        }
    }

    // MARK: - handlers

    /// Maps a shell route path to the static HTML file that serves it.
    ///
    /// Both `/simulators/<udid>` and `/m/<udid>` return `sim.html` — the
    /// client JS reads the URL path and routes the inner focus view (the
    /// `/m/` prefix is the thumb-friendly mobile entry point). A *bare*
    /// `/m` or `/farm` (no second path segment) stays the device-farm
    /// dashboard. The discriminator is the same one the JS activation
    /// gate uses: a non-empty second segment means "single device".
    static func shellAsset(forPath path: String) -> String {
        let segments = path.split(separator: "/").map(String.init)
        switch segments.first {
        case "m", "farm":
            return segments.count >= 2 ? "sim.html" : "farm/farm.html"
        default:
            // `/simulators`, `/simulators/<udid>`, and anything else that
            // reaches a shell route render the sim shell.
            return "sim.html"
        }
    }

    static func staticAsset(_ name: String) -> Response {
        guard let data = WebRoot.data(named: name) else {
            return Response(
                status: .notFound,
                headers: [
                    .contentType: "text/plain; charset=utf-8",
                    .contentSecurityPolicy: "frame-ancestors 'none'",
                ],
                body: .init(byteBuffer: ByteBuffer(string:
                    "missing \(name) — set BAGUETTE_WEB_DIR or rebuild"
                ))
            )
        }
        return Response(
            status: .ok,
            headers: [
                .contentType: contentType(for: name),
                .cacheControl: "no-cache",
                .contentSecurityPolicy: "frame-ancestors 'none'",
            ],
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }

    private static func listJSON(_ simulators: any Simulators) -> Response {
        Response(
            status: .ok,
            headers: [.contentType: "application/json", .cacheControl: "no-cache"],
            body: .init(byteBuffer: ByteBuffer(string: simulators.listJSON))
        )
    }

    private static func versionJSON() -> Response {
        let body = #"{"service":"agent-sim","version":"\#(agentSimVersion)"}"#
        return Response(
            status: .ok,
            headers: [.contentType: "application/json", .cacheControl: "no-cache"],
            body: .init(byteBuffer: ByteBuffer(string: body))
        )
    }

    /// Outcome of `applyOrientation` — one case per HTTP-status
    /// branch the orientation route maps to. Lives next to the
    /// helper so the route closure in `addRoutes(...)` is just a
    /// `switch outcome → Response` translation.
    enum OrientationOutcome: Equatable {
        case ok
        case invalidValue
        case unknownDevice
        case dispatchFailed
    }

    /// Pure parse + dispatch: validate `value`, look up the
    /// simulator, and run `simulator.orientation().set(...)`. Split
    /// out from the route closure so unit tests can drive every
    /// branch (`MockSimulators` + `MockOrientation`) without booting
    /// Hummingbird.
    static func applyOrientation(
        udid: String,
        value: String,
        simulators: any Simulators
    ) -> OrientationOutcome {
        guard let orientation = DeviceOrientation(wireName: value) else {
            return .invalidValue
        }
        guard !udid.isEmpty, let sim = simulators.find(udid: udid) else {
            return .unknownDevice
        }
        return sim.orientation().set(orientation) ? .ok : .dispatchFailed
    }

    private static func lifecycle(
        udid: String,
        simulators: any Simulators,
        action: (Simulator) throws -> Void
    ) -> Response {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid) else {
            return errorJSON("unknown udid: \(udid)", status: .notFound)
        }
        do {
            try action(sim)
            return jsonOK
        } catch {
            return errorJSON(String(describing: error), status: .internalServerError)
        }
    }

    private static func chromeJSON(
        udid: String,
        simulators: any Simulators,
        chromes: any Chromes
    ) -> Response {
        guard let json = chromeJSONString(
            udid: udid, simulators: simulators, chromes: chromes
        ) else {
            return errorJSON("no chrome for udid \(udid)", status: .notFound)
        }
        return Response(
            status: .ok,
            headers: [.contentType: "application/json", .cacheControl: "no-cache"],
            body: .init(byteBuffer: ByteBuffer(string: json))
        )
    }

    /// Pure data producer for `chrome.json`. Internal so handler-level
    /// tests can drive it with mock `Simulators` + `Chromes` and assert
    /// on the JSON string directly. The route closure (`chromeJSON`)
    /// is the thin wrapper that builds the `Response`.
    ///
    /// Includes `imageUrl` per button — the actionable-bezel front end
    /// fetches each rasterized button from the
    /// `/simulators/<udid>/chrome-button/<name>.png` route below.
    static func chromeJSONString(
        udid: String,
        simulators: any Simulators,
        chromes: any Chromes
    ) -> String? {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid),
              let assets = sim.chrome(in: chromes) else {
            return nil
        }
        return assets.layoutJSON(
            buttonImageURLPrefix: "/simulators/\(udid)/chrome-button/"
        )
    }

    private static func screenshotJPEG(
        udid: String,
        quality: Double,
        scale: Int,
        simulators: any Simulators
    ) async -> Response {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid) else {
            return errorJSON("unknown udid: \(udid)", status: .notFound)
        }
        do {
            let bytes = try await ScreenSnapshot.capture(
                screen: sim.screen(),
                quality: quality,
                scale: max(1, scale)
            )
            return Response(
                status: .ok,
                headers: [.contentType: "image/jpeg", .cacheControl: "no-cache"],
                body: .init(byteBuffer: ByteBuffer(data: bytes))
            )
        } catch {
            return errorJSON(String(describing: error), status: .internalServerError)
        }
    }

    private static func bezelPNG(
        udid: String,
        simulators: any Simulators,
        chromes: any Chromes,
        withButtons: Bool = true
    ) -> Response {
        guard let bytes = bezelImage(
            udid: udid, simulators: simulators,
            chromes: chromes, withButtons: withButtons
        ) else {
            return Response(
                status: .notFound,
                headers: [.contentType: "text/plain"],
                body: .init(byteBuffer: ByteBuffer(string: "no bezel for \(udid)"))
            )
        }
        return Response(
            status: .ok,
            headers: [.contentType: "image/png", .cacheControl: "public, max-age=86400"],
            body: .init(byteBuffer: ByteBuffer(data: bytes))
        )
    }

    /// Pure data producer for the bezel image. Returns `nil` for
    /// unknown UDIDs / chromes so the route closure can collapse to
    /// 404 uniformly.
    ///
    /// `withButtons: false` returns the bare device body (`?buttons=
    /// false` on the route) — the actionable-bezel front end layers
    /// per-button images on top, animating each independently.
    /// `withButtons: true` (the default) returns the merged composite
    /// — today's behaviour.
    static func bezelImage(
        udid: String,
        simulators: any Simulators,
        chromes: any Chromes,
        withButtons: Bool
    ) -> Data? {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid),
              let assets = sim.chrome(in: chromes) else {
            return nil
        }
        return withButtons ? assets.composite.data : assets.bareComposite.data
    }

    private static func chromeButtonPNG(
        udid: String,
        buttonFile: String,
        simulators: any Simulators,
        chromes: any Chromes
    ) -> Response {
        guard let bytes = chromeButtonImage(
            udid: udid, buttonFile: buttonFile,
            simulators: simulators, chromes: chromes
        ) else {
            return Response(
                status: .notFound,
                headers: [.contentType: "text/plain"],
                body: .init(byteBuffer: ByteBuffer(
                    string: "no button \(buttonFile) for \(udid)"
                ))
            )
        }
        return Response(
            status: .ok,
            headers: [.contentType: "image/png", .cacheControl: "public, max-age=86400"],
            body: .init(byteBuffer: ByteBuffer(data: bytes))
        )
    }

    /// Pure data producer for the per-button image route. `buttonFile`
    /// is the last URL path segment (e.g. `"powerButton.png"`). The
    /// `.png` extension is stripped — the front end may or may not
    /// include it, both spellings resolve the same button. Returns
    /// `nil` when the udid / chrome / button name is unknown so the
    /// route 404s uniformly.
    static func chromeButtonImage(
        udid: String,
        buttonFile: String,
        simulators: any Simulators,
        chromes: any Chromes
    ) -> Data? {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid),
              let assets = sim.chrome(in: chromes) else {
            return nil
        }
        let name: String = {
            if buttonFile.hasSuffix(".png") {
                return String(buttonFile.dropLast(4))
            }
            return buttonFile
        }()
        return assets.buttonImages[name]?.data
    }

    /// One WebSocket = one streaming session. Opens Screen + Stream
    /// + WS sink, runs until the client disconnects. Every inbound
    /// text frame is one JSON line dispatched in this order:
    ///   1. ReconfigParser   — set_bitrate / set_fps / set_scale
    ///   2. stream verbs     — force_idr / snapshot
    ///   3. GestureDispatcher — tap / swipe / touch1-* / touch2-* /
    ///      button / scroll / pinch / pan / key / type
    /// Lines not matched by any of the above are ignored — same
    /// graceful behaviour the stdin control channel has.
    private static func streamWS(
        udid: String,
        format: StreamFormat,
        simulators: any Simulators,
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter
    ) async {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid) else {
            try? await outbound.write(.text(#"{"ok":false,"error":"unknown udid"}"#))
            return
        }

        let sink = WebSocketFrameSink(outbound: outbound, format: format)
        let stream = format.makeStream(config: .default, sink: sink, quality: 0.5)
        let screen = sim.screen()
        let dispatcher = GestureDispatcher(input: sim.input())

        do {
            try stream.start(on: screen)
        } catch {
            try? await outbound.write(.text(
                #"{"ok":false,"error":"\#(jsonEscape(String(describing: error)))"}"#
            ))
            return
        }
        defer {
            stream.stop()
            screen.stop()
        }

        do {
            for try await frame in inbound {
                guard frame.opcode == .text else { continue }
                let line = String(buffer: frame.data)
                if await handleDescribeUI(
                    line: line, sim: sim, outbound: outbound
                ) {
                    continue
                }
                handleInbound(
                    line: line,
                    stream: stream,
                    dispatcher: dispatcher
                )
            }
        } catch {
            // socket closed; defer cleans up
        }
    }

    /// `describe_ui` text message — needs the `Simulator` (to reach
    /// the AX port) and the outbound writer (to ship the result
    /// back), neither of which `handleInbound` carries. Returns
    /// `true` when the line was a `describe_ui` envelope (handled
    /// or rejected with an error JSON), `false` for any other
    /// shape so the caller falls through to the gesture / reconfig
    /// pipeline.
    private static func handleDescribeUI(
        line: String,
        sim: Simulator,
        outbound: WebSocketOutboundWriter
    ) async -> Bool {
        guard let request = DescribeUIWire.parse(line) else { return false }
        let ax = sim.accessibility()
        let result: AXNode?
        let error: Error?
        do {
            if let point = request.point {
                result = try ax.describeAt(point: point)
            } else {
                result = try ax.describeAll()
            }
            error = nil
        } catch let e {
            result = nil
            error = e
        }
        try? await outbound.write(.text(
            DescribeUIWire.reply(request: request, result: result, error: error)
        ))
        return true
    }

    /// Register the `/simulators/:udid/logs` WebSocket route. Lives
    /// in its own helper because Hummingbird's router-builder
    /// inference grinds to a halt when too many `router.ws` /
    /// `router.get` closures share a single function body.
    private func registerLogsRoute(on router: Router<BasicWebSocketRequestContext>) {
        let simulators = self.simulators
        let bindHost = self.host
        let bindPort = self.port
        let staticTrusted = self.trustedHosts
        let dynamicTrusted = self.dynamicTrustedHosts
        let trustedWebSocketUpgrade:
            @Sendable (Request, BasicWebSocketRequestContext) async throws -> RouterShouldUpgrade = {
                request, _ in
                Self.isTrustedBrowserRequest(
                    request, bindHost: bindHost, bindPort: bindPort,
                    trustedHosts: Self.effectiveTrustedHosts(
                        static: staticTrusted, dynamic: dynamicTrusted()
                    )
                ) ? .upgrade([:]) : .dontUpgrade
            }
        router.ws(
            "/simulators/:udid/logs",
            shouldUpgrade: trustedWebSocketUpgrade
        ) { inbound, outbound, context in
            let req = context.request
            let opts = LogsRouteOptions.from(request: req)
            await Self.logsWS(
                opts: opts,
                simulators: simulators,
                inbound: inbound,
                outbound: outbound
            )
        }
    }

    /// Live log-stream over the dedicated `/simulators/:udid/logs`
    /// WebSocket. Filter is fixed at connect time via query string
    /// (`level`, `style`, `predicate`, `bundleId`). The spawned
    /// `/usr/bin/log stream` child runs for the lifetime of the
    /// socket; closing the socket from either end tears it down.
    ///
    /// Wire envelopes (server → client text frames):
    ///   {"type":"log_started"}
    ///   {"type":"log","lines":["<line>", "<line>", …]}
    ///   {"type":"log_stopped","reason":"<text>"}
    ///
    /// Lines are coalesced through `LogBatcher` (size cap + 50 ms
    /// window): per-line WS frames pegged the browser's main thread
    /// at CoreDuet-chatter rates because the per-frame parse +
    /// dispatch + render cost dwarfs the bytes themselves. One
    /// frame per ~50 ms drops that to ~20 frames/sec and decouples
    /// log volume from UI responsiveness.
    ///
    /// Client → server: a single `{"type":"stop"}` text frame
    /// terminates early. Otherwise the server waits for the child
    /// to exit or the socket to close.
    private static func logsWS(
        opts: LogsRouteOptions,
        simulators: any Simulators,
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter
    ) async {
        guard !opts.udid.isEmpty, let sim = simulators.find(udid: opts.udid) else {
            try? await outbound.write(.text(#"{"type":"log_stopped","reason":"unknown udid"}"#))
            return
        }
        guard let lvl = LogFilter.Level(wire: opts.level) else {
            try? await outbound.write(.text(
                #"{"type":"log_stopped","reason":"invalid level: \#(opts.level)"}"#
            ))
            return
        }
        guard let sty = LogFilter.Style(wire: opts.style) else {
            try? await outbound.write(.text(
                #"{"type":"log_stopped","reason":"invalid style: \#(opts.style)"}"#
            ))
            return
        }
        let filter = LogFilter(
            level: lvl, style: sty,
            predicate: opts.predicate, bundleId: opts.bundleId
        )

        let stream = sim.logs()
        let lineQueue = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(2048))

        do {
            try stream.start(
                filter: filter,
                onLine: { line in
                    lineQueue.continuation.yield(line)
                },
                onTerminate: { _ in
                    lineQueue.continuation.finish()
                }
            )
        } catch {
            try? await outbound.write(.text(
                #"{"type":"log_stopped","reason":"\#(jsonEscape(String(describing: error)))"}"#
            ))
            return
        }

        try? await outbound.write(.text(#"{"type":"log_started"}"#))
        defer { stream.stop() }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                // Multiplex lines and a 50ms ticker into one stream so a
                // single consumer can own the batcher without locking.
                enum Event { case line(String); case tick; case end }
                let events = AsyncStream<Event>(bufferingPolicy: .bufferingNewest(4096)) { cont in
                    let lineTask = Task {
                        for await line in lineQueue.stream {
                            cont.yield(.line(line))
                        }
                        cont.yield(.end)
                        cont.finish()
                    }
                    let tickTask = Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 50_000_000)
                            if Task.isCancelled { break }
                            cont.yield(.tick)
                        }
                    }
                    cont.onTermination = { _ in
                        lineTask.cancel()
                        tickTask.cancel()
                    }
                }

                var batcher = LogBatcher(maxLines: 200, windowMs: 50)
                consumer: for await event in events {
                    let batch: [String]?
                    switch event {
                    case .line(let line): batch = batcher.ingest(line, now: Date())
                    case .tick:           batch = batcher.tick(now: Date())
                    case .end:
                        if let final = batcher.flush() {
                            _ = try? await outbound.write(.text(envelope(forBatch: final)))
                        }
                        break consumer
                    }
                    if let batch {
                        if (try? await outbound.write(.text(envelope(forBatch: batch)))) == nil {
                            break consumer
                        }
                    }
                }
            }
            group.addTask {
                do {
                    for try await frame in inbound {
                        guard frame.opcode == .text else { continue }
                        let line = String(buffer: frame.data)
                        if let data = line.data(using: .utf8),
                           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           (dict["type"] as? String) == "stop" {
                            break
                        }
                    }
                } catch {
                    // socket closed; defer cleans up
                }
            }
            await group.next()
            group.cancelAll()
        }
        try? await outbound.write(.text(#"{"type":"log_stopped","reason":"client closed"}"#))
    }

    /// Triage one upstream text line: stream config first (cheapest
    /// to detect), then format-level verbs, then gesture dispatch as
    /// the catch-all. ReconfigParser returns the same config when
    /// the line wasn't a `set_*` — that's our discriminator.
    private static func handleInbound(
        line: String,
        stream: any Stream,
        dispatcher: GestureDispatcher
    ) {
        let next = ReconfigParser.apply(line, to: stream.config)
        if next != stream.config {
            stream.apply(next)
            return
        }
        if let data = line.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let kind = dict["type"] as? String {
            switch kind {
            case "force_idr": stream.requestKeyframe(); return
            case "snapshot":  stream.requestSnapshot(); return
            default: break
            }
        }
        _ = dispatcher.dispatch(line: line)
    }

    // MARK: - review handlers

    private static func reviewListJSON(store: any ReviewStore) -> Response {
        do {
            let data = try jsonEncoder.encode(store.listSessions())
            return jsonResponse(data)
        } catch {
            return errorJSON(String(describing: error), status: .internalServerError)
        }
    }

    private static func createReview(
        request: Request,
        store: any ReviewStore
    ) async -> Response {
        do {
            let body = try await decodeJSON(CreateReviewBody.self, from: request)
            let session = try store.createSession(name: body.name ?? "")
            return jsonResponse(try jsonEncoder.encode(session))
        } catch {
            return errorJSON(String(describing: error), status: .badRequest)
        }
    }

    private static func reviewManifestJSON(id: String, store: any ReviewStore) -> Response {
        do {
            let session = try store.loadSession(id: id)
            return jsonResponse(try jsonEncoder.encode(session))
        } catch ReviewStoreError.notFound {
            return errorJSON("unknown review: \(id)", status: .notFound)
        } catch {
            return errorJSON(String(describing: error), status: .internalServerError)
        }
    }

    private static func captureReview(
        id: String,
        request: Request,
        simulators: any Simulators,
        store: any ReviewStore
    ) async -> Response {
        do {
            let input = try await decodeJSON(ReviewCaptureInput.self, from: request)
            let result = try await ReviewCaptureService.capture(
                input: input,
                sessionId: id,
                simulators: simulators,
                store: store
            )
            return jsonResponse(try jsonEncoder.encode(result))
        } catch SimulatorError.notFound(let udid) {
            return errorJSON("unknown udid: \(udid)", status: .notFound)
        } catch ReviewStoreError.notFound {
            return errorJSON("unknown review: \(id)", status: .notFound)
        } catch {
            return errorJSON(String(describing: error), status: .badRequest)
        }
    }

    private static func addReviewEdge(
        id: String,
        request: Request,
        store: any ReviewStore
    ) async -> Response {
        do {
            let body = try await decodeJSON(ReviewEdgeInput.self, from: request)
            let edge = ReviewEdge(
                id: FileReviewStore.makeID(prefix: "edge"),
                fromSnapshotId: body.fromSnapshotId,
                toSnapshotId: body.toSnapshotId,
                actionType: body.actionType,
                axNodePath: body.axNodePath,
                gestureJSON: body.gestureJSON,
                timestamp: Date()
            )
            var session = try store.loadSession(id: id)
            session.edges.append(edge)
            try store.saveSession(session)
            return jsonResponse(try jsonEncoder.encode(edge))
        } catch ReviewStoreError.notFound {
            return errorJSON("unknown review: \(id)", status: .notFound)
        } catch {
            return errorJSON(String(describing: error), status: .badRequest)
        }
    }

    private static func addReviewComment(
        id: String,
        request: Request,
        store: any ReviewStore
    ) async -> Response {
        do {
            let body = try await decodeJSON(ReviewCommentInput.self, from: request)
            let comment = ReviewElementComment(
                id: FileReviewStore.makeID(prefix: "comment"),
                snapshotId: body.snapshotId,
                axNodePath: body.axNodePath,
                frame: body.frame,
                text: body.text,
                status: body.status ?? "open",
                createdAt: Date()
            )
            var session = try store.loadSession(id: id)
            session.comments.append(comment)
            try store.saveSession(session)
            return jsonResponse(try jsonEncoder.encode(comment))
        } catch ReviewStoreError.notFound {
            return errorJSON("unknown review: \(id)", status: .notFound)
        } catch {
            return errorJSON(String(describing: error), status: .badRequest)
        }
    }

    private static func createReviewBundle(
        id: String,
        request: Request,
        store: any ReviewStore
    ) async -> Response {
        do {
            let body = try await decodeJSON(ReviewBundleInput.self, from: request)
            var session = try store.loadSession(id: id)
            let bundle = try makeReviewBundle(input: body, session: session, store: store)
            session.bundles.append(bundle)
            try store.saveSession(session)
            return jsonResponse(try jsonEncoder.encode(bundle))
        } catch ReviewStoreError.notFound {
            return errorJSON("unknown review: \(id)", status: .notFound)
        } catch {
            return errorJSON(String(describing: error), status: .badRequest)
        }
    }

    private static func createReviewFlow(
        id: String,
        request: Request,
        store: any ReviewStore
    ) async -> Response {
        do {
            let body = try await decodeJSON(ReviewFlowCreateInput.self, from: request)
            var session = try store.loadSession(id: id)
            let flow = ReviewFlow(
                id: FileReviewStore.makeID(prefix: "flow"),
                sessionId: id,
                name: body.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Untitled flow" : body.name,
                steps: body.steps,
                createdAt: Date(),
                createdBy: body.createdBy
            )
            session.flows.append(flow)
            try store.saveSession(session)
            return jsonResponse(try jsonEncoder.encode(flow))
        } catch ReviewStoreError.notFound {
            return errorJSON("unknown review: \(id)", status: .notFound)
        } catch {
            return errorJSON(String(describing: error), status: .badRequest)
        }
    }

    private static func listReviewFlows(id: String, store: any ReviewStore) -> Response {
        do {
            let session = try store.loadSession(id: id)
            return jsonResponse(try jsonEncoder.encode(session.flows))
        } catch ReviewStoreError.notFound {
            return errorJSON("unknown review: \(id)", status: .notFound)
        } catch {
            return errorJSON(String(describing: error), status: .internalServerError)
        }
    }

    private static func replayReviewFlow(
        id: String,
        flowId: String,
        request: Request,
        store: any ReviewStore,
        simulators: any Simulators
    ) async -> Response {
        do {
            let body = try await decodeJSON(ReviewFlowReplayInput.self, from: request)
            let session = try store.loadSession(id: id)
            guard let flow = session.flows.first(where: { $0.id == flowId }) else {
                return errorJSON("unknown flow: \(flowId)", status: .notFound)
            }
            let result = try await FlowReplayService.replay(
                flow: flow,
                udid: body.udid,
                pacing: body.pacing ?? .fast,
                simulators: simulators
            )
            let payload: [String: Any] = [
                "ok": result.lastOK,
                "executed": result.executed,
                "flowId": flow.id,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            return jsonResponse(data)
        } catch SimulatorError.notFound(let udid) {
            return errorJSON("unknown udid: \(udid)", status: .notFound)
        } catch ReviewStoreError.notFound {
            return errorJSON("unknown review: \(id)", status: .notFound)
        } catch let error as FlowReplayError {
            return errorJSON(error.description, status: .badRequest)
        } catch {
            return errorJSON(String(describing: error), status: .badRequest)
        }
    }

    private static func uploadReviewRecording(
        id: String,
        request: Request,
        store: any ReviewStore
    ) async -> Response {
        let q = request.uri.queryParameters
        let contentType = q.get("contentType") ?? "video/webm"
        let from = q.get("from")
        let to = q.get("to")
        let duration = q.get("duration").flatMap(Double.init)
        let rawName = q.get("name") ?? ""
        do {
            var buffer = try await request.body.collect(upTo: 200 * 1024 * 1024)
            let bytes = buffer.readableBytes
            guard bytes > 0 else {
                return errorJSON("empty recording body", status: .badRequest)
            }
            let data = buffer.readData(length: bytes) ?? Data()

            var session = try store.loadSession(id: id)
            let recId = FileReviewStore.makeID(prefix: "rec")
            let ext = recordingExtension(for: contentType)
            let safeName = recordingFilename(preferred: rawName, fallback: "recording-\(recId).\(ext)")
            let relativePath = "recordings/\(recId)/\(safeName)"
            try store.writeArtifact(sessionId: id, relativePath: relativePath, data: data)

            let recording = ReviewRecording(
                id: recId,
                sessionId: id,
                filename: relativePath,
                contentType: contentType,
                bytes: data.count,
                durationSeconds: duration,
                fromSnapshotId: from,
                toSnapshotId: to,
                createdAt: Date()
            )
            session.recordings.append(recording)
            try store.saveSession(session)
            return jsonResponse(try jsonEncoder.encode(recording))
        } catch ReviewStoreError.notFound {
            return errorJSON("unknown review: \(id)", status: .notFound)
        } catch {
            return errorJSON(String(describing: error), status: .badRequest)
        }
    }

    private static func listReviewRecordings(id: String, store: any ReviewStore) -> Response {
        do {
            let session = try store.loadSession(id: id)
            return jsonResponse(try jsonEncoder.encode(session.recordings))
        } catch ReviewStoreError.notFound {
            return errorJSON("unknown review: \(id)", status: .notFound)
        } catch {
            return errorJSON(String(describing: error), status: .internalServerError)
        }
    }

    private static func recordingExtension(for contentType: String) -> String {
        if contentType.hasPrefix("video/mp4") { return "mp4" }
        if contentType.hasPrefix("video/webm") { return "webm" }
        return "bin"
    }

    private static func recordingFilename(preferred: String, fallback: String) -> String {
        let trimmed = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        // Drop any traversal — only keep the final path component, sanitised.
        let base = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "._-"))
        let cleaned = base.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "_" }
            .reduce(into: "") { $0.append($1) }
        return cleaned.isEmpty ? fallback : cleaned
    }

    private static func reviewSourceSearch(request: Request) async -> Response {
        do {
            let input = try await decodeJSON(ReviewSourceSearchInput.self, from: request)
            let result = try ReviewSourceSearcher.search(input)
            return jsonResponse(try jsonEncoder.encode(result))
        } catch {
            return errorJSON(String(describing: error), status: .badRequest)
        }
    }

    /// External snapshot ingestion. Lets a non-simulator source push
    /// a screenshot + (optionally) AX elements into a review session.
    /// Used by `examples/agent/agent_canvas_to_agentsim.py` and any
    /// other tool that has artefacts but doesn't drive the simulator.
    /// Returns the same `ReviewCaptureResult` shape as the live capture
    /// route; `edge` is always nil here.
    private static func importReviewSnapshot(
        id: String,
        request: Request,
        store: any ReviewStore
    ) async -> Response {
        do {
            let input = try await decodeJSON(ReviewSnapshotImportInput.self, from: request)
            let result = try ReviewSnapshotImportService.importSnapshot(
                input: input, sessionId: id, store: store
            )
            return jsonResponse(try jsonEncoder.encode(result))
        } catch ReviewStoreError.notFound(_) {
            return errorJSON("unknown review: \(id)", status: .notFound)
        } catch let error as ReviewSnapshotImportError {
            return errorJSON(String(describing: error), status: .badRequest)
        } catch {
            return errorJSON(String(describing: error), status: .badRequest)
        }
    }

    /// Skinny bulk create — accepts a JSON envelope of N items + shared
    /// defaults, returns `{created, errors}` so partial-success is
    /// visible. Does NOT generate per-task bundles or context.md;
    /// callers that need those go through the single-task route
    /// (`POST /reviews/:id/tasks`) which keeps the interactive bundle
    /// flow. Use case: external sources (e.g. an agent-canvas route
    /// inventory) want to queue N tasks for the agent in one call.
    private static func bulkCreateReviewTasks(
        id: String,
        request: Request,
        taskStore: any ReviewTaskStore
    ) async -> Response {
        do {
            let bodyInput = try await decodeJSON(ReviewTaskBulkCreateInput.self, from: request)
            // Path id wins so the caller can't accidentally retarget
            // a batch by mutating the body alone.
            let input = ReviewTaskBulkCreateInput(
                sessionId: id,
                defaults: bodyInput.defaults,
                tasks: bodyInput.tasks
            )
            let result = try taskStore.bulkCreateTasks(input: input)
            return jsonResponse(try jsonEncoder.encode(result))
        } catch {
            return errorJSON(String(describing: error), status: .badRequest)
        }
    }

    private static func createReviewTask(
        id: String,
        request: Request,
        store: any ReviewStore,
        taskStore: any ReviewTaskStore
    ) async -> Response {
        do {
            let input = try await decodeJSON(ReviewTaskCreateInput.self, from: request)
            var session = try store.loadSession(id: id)
            let bundle = try ensureBundle(input: input, session: &session, store: store)
            try store.saveSession(session)

            let taskId = FileReviewStore.makeID(prefix: "task")
            let contextPath = "tasks/\(taskId)/context.md"
            let snapshotIds = input.snapshotIds.isEmpty ? bundle?.snapshotIds ?? [] : input.snapshotIds
            let elements = taskElements(
                taskId: taskId,
                input: input,
                session: session
            )
            let contextMarkdown = input.contextMarkdown ?? taskContextMarkdown(
                session: session,
                bundle: bundle,
                snapshotIds: snapshotIds,
                elements: elements
            )
            try store.writeArtifact(
                sessionId: session.id,
                relativePath: contextPath,
                data: Data(contextMarkdown.utf8)
            )
            let task = reviewTaskFromCreateInput(
                taskId: taskId,
                sessionId: session.id,
                input: input,
                bundle: bundle,
                contextPath: contextPath,
                elements: elements,
                now: Date()
            )
            return jsonResponse(try jsonEncoder.encode(try taskStore.createTask(task)))
        } catch ReviewStoreError.notFound {
            return errorJSON("unknown review: \(id)", status: .notFound)
        } catch {
            return errorJSON(String(describing: error), status: .badRequest)
        }
    }

    private static func reviewTaskListJSON(
        sessionId: String?,
        status: String?,
        taskStore: any ReviewTaskStore
    ) -> Response {
        do {
            return jsonResponse(try jsonEncoder.encode(
                try taskStore.listTasks(sessionId: sessionId, status: status)
            ))
        } catch {
            return errorJSON(String(describing: error), status: .internalServerError)
        }
    }

    private static func reviewTaskJSON(id: String, taskStore: any ReviewTaskStore) -> Response {
        do {
            return jsonResponse(try jsonEncoder.encode(try taskStore.loadTask(id: id)))
        } catch ReviewTaskStoreError.notFound {
            return errorJSON("unknown task: \(id)", status: .notFound)
        } catch {
            return errorJSON(String(describing: error), status: .internalServerError)
        }
    }

    // MARK: - Notes queue (session-less)

    /// Append a left message. Returns the stored note as JSON, or nil
    /// when the message is blank or the store rejects it (→ 400).
    static func createdNoteJSONString(_ input: NoteCreateInput, store: any Notes) -> String? {
        guard !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let note = try? store.add(input),
              let data = try? jsonEncoder.encode(note) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The inbox newest-first as JSON, or nil on a store failure (→ 500).
    static func notesInboxJSONString(store: any Notes) -> String? {
        guard let inbox = try? store.list(),
              let data = try? jsonEncoder.encode(inbox) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The status-filtered inbox wrapped in a `notes_snapshot`
    /// envelope (newest-first), or nil on a store failure. This is the
    /// frame `WS /notes/stream` diff-and-pushes; `status` is parsed
    /// leniently through `NoteFilter` (nil / unknown ⇒ all).
    static func notesStreamSnapshotJSONString(
        store: any Notes,
        status: String?
    ) -> String? {
        guard let inbox = try? store.list() else { return nil }
        let filtered = NoteFilter.from(status).apply(to: inbox)
        guard let data = try? jsonEncoder.encode(NotesStreamSnapshot(notes: filtered)) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Promote a note: flip it to picked-up *and* file it as a real
    /// review task in the shared `notes` backlog (anchored to its AX
    /// node when it had one). Returns a `{note, task}` envelope as
    /// JSON. Nil when no note has that id (→ 404). The flag flip is
    /// the source of truth for "picked up"; if bulk-create yields no
    /// task we still surface the promoted note with `task: null`
    /// rather than failing the pick-up.
    static func promoteNoteJSONString(
        id: String,
        notes: any Notes,
        taskStore: any ReviewTaskStore
    ) -> String? {
        guard let note = try? notes.promote(id: id) else { return nil }
        let task = (try? taskStore.bulkCreateTasks(
            input: note.reviewTaskBulkCreateInput()
        ))?.created.first
        guard let data = try? jsonEncoder.encode(
            NotePromotionResult(note: note, task: task)
        ) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Triangulate

    /// Resolves `{udid, x, y}` to the AX node at the point plus the
    /// workspace discovered via Metro. Returns nil when the udid is
    /// unknown (→ 404). The AX error path is folded into the envelope
    /// as a null node; an unreachable Metro yields a null workspace.
    /// Phase A always emits `candidates: []`.
    static func triangulateJSONString(
        input: TriangulateInput,
        simulators: any Simulators,
        metro: any Metro,
        listFiles: (URL) -> [URL] = JSXScanner.defaultListFiles,
        readFile: (URL) -> String? = { try? String(contentsOf: $0) }
    ) async -> String? {
        guard let sim = simulators.find(udid: input.udid) else { return nil }
        let result: TriangulationResult
        do {
            result = try await Triangulate.run(
                point: Point(x: input.x, y: input.y),
                accessibility: sim.accessibility(),
                metro: metro,
                listFiles: listFiles,
                readFile: readFile
            )
        } catch {
            let ws = await Workspace.discover(metro: metro, readFile: readFile)
            result = TriangulationResult(node: nil, workspace: ws, candidates: [])
        }
        return result.json
    }

    private static func claimNextReviewTask(
        request: Request,
        taskStore: any ReviewTaskStore
    ) async -> Response {
        do {
            let input = try await decodeJSON(ReviewTaskClaimInput.self, from: request)
            guard let task = try taskStore.claimNext(agentId: input.agentId) else {
                return jsonResponse(Data("null".utf8))
            }
            return jsonResponse(try jsonEncoder.encode(task))
        } catch {
            return errorJSON(String(describing: error), status: .badRequest)
        }
    }

    private static func claimReviewTask(
        id: String,
        request: Request,
        taskStore: any ReviewTaskStore
    ) async -> Response {
        do {
            let input = try await decodeJSON(ReviewTaskClaimInput.self, from: request)
            return jsonResponse(try jsonEncoder.encode(
                try taskStore.claimTask(id: id, agentId: input.agentId)
            ))
        } catch ReviewTaskStoreError.notFound {
            return errorJSON("unknown task: \(id)", status: .notFound)
        } catch {
            return errorJSON(String(describing: error), status: .badRequest)
        }
    }

    private static func updateReviewTask(
        id: String,
        request: Request,
        taskStore: any ReviewTaskStore,
        reviewStore: any ReviewStore
    ) async -> Response {
        do {
            let input = try await decodeJSON(ReviewTaskUpdateInput.self, from: request)
            // `?verify=1` opts into auto-grading the criteria against the
            // just-attached snapshot (ADR-0002). Off by default → plain update.
            let autoVerify = ["1", "true"].contains(
                String(request.uri.queryParameters.get("verify") ?? ""))
            return jsonResponse(try jsonEncoder.encode(
                try LoopRoutes.submitResult(
                    autoVerify: autoVerify, taskId: id, input: input,
                    taskStore: taskStore, reviewStore: reviewStore)
            ))
        } catch ReviewTaskStoreError.notFound {
            return errorJSON("unknown task: \(id)", status: .notFound)
        } catch {
            return errorJSON(String(describing: error), status: .badRequest)
        }
    }

    private static func appendReviewTaskEvent(
        id: String,
        request: Request,
        taskStore: any ReviewTaskStore
    ) async -> Response {
        do {
            let input = try await decodeJSON(ReviewTaskEventInput.self, from: request)
            return jsonResponse(try jsonEncoder.encode(
                try taskStore.appendEvent(taskId: id, input: input)
            ))
        } catch ReviewTaskStoreError.notFound {
            return errorJSON("unknown task: \(id)", status: .notFound)
        } catch {
            return errorJSON(String(describing: error), status: .badRequest)
        }
    }

    private static func appendReviewTaskCodeChanges(
        id: String,
        request: Request,
        taskStore: any ReviewTaskStore
    ) async -> Response {
        do {
            let input = try await decodeJSON(ReviewTaskCodeChangesInput.self, from: request)
            return jsonResponse(try jsonEncoder.encode(
                try taskStore.appendCodeChanges(taskId: id, input: input)
            ))
        } catch ReviewTaskStoreError.notFound {
            return errorJSON("unknown task: \(id)", status: .notFound)
        } catch {
            return errorJSON(String(describing: error), status: .badRequest)
        }
    }

    private static func verifyReviewTask(
        id: String,
        request: Request,
        taskStore: any ReviewTaskStore
    ) async -> Response {
        do {
            let input = try await decodeJSON(ReviewTaskVerificationInput.self, from: request)
            let verification = ReviewTaskVerification(
                id: FileReviewStore.makeID(prefix: "verify"),
                taskId: id,
                beforeSnapshotIds: input.beforeSnapshotIds ?? [],
                afterSnapshotId: input.afterSnapshotId,
                status: input.status,
                notes: input.notes,
                createdAt: Date()
            )
            return jsonResponse(try jsonEncoder.encode(
                try taskStore.addVerification(taskId: id, verification: verification)
            ))
        } catch ReviewTaskStoreError.notFound {
            return errorJSON("unknown task: \(id)", status: .notFound)
        } catch {
            return errorJSON(String(describing: error), status: .badRequest)
        }
    }

    private static func reviewTasksWS(
        sessionId: String?,
        status: String?,
        taskStore: any ReviewTaskStore,
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter
    ) async {
        try? await outbound.write(.text(#"{"type":"task_stream_started"}"#))
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var lastPayload = Data()
                var lastTasksByID: [String: ReviewTask] = [:]
                var hasSeenTasks = false
                while !Task.isCancelled {
                    do {
                        let tasks = try taskStore.listTasks(sessionId: sessionId, status: status)
                        let currentTasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
                        if hasSeenTasks {
                            for task in tasks where lastTasksByID[task.id] != task {
                                let update = try jsonEncoder.encode(TaskStreamTask(type: "task_update", task: task))
                                try await outbound.write(.text(String(decoding: update, as: UTF8.self)))
                            }
                        }
                        lastTasksByID = currentTasksByID
                        hasSeenTasks = true
                        let payload = try jsonEncoder.encode(TaskStreamSnapshot(tasks: tasks))
                        if payload != lastPayload {
                            lastPayload = payload
                            try await outbound.write(.text(String(decoding: payload, as: UTF8.self)))
                        }
                    } catch {
                        try? await outbound.write(.text(
                            #"{"type":"task_stream_error","error":"\#(jsonEscape(String(describing: error)))"}"#
                        ))
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            group.addTask {
                do {
                    for try await frame in inbound {
                        guard frame.opcode == .text else { continue }
                        let line = String(buffer: frame.data)
                        if Self.isWSStopFrame(line) { break }
                        if await handleReviewTaskWSLine(
                            line: line,
                            taskStore: taskStore,
                            outbound: outbound
                        ) {
                            continue
                        }
                    }
                } catch {
                    // socket closed; sibling task is cancelled below
                }
            }
            await group.next()
            group.cancelAll()
        }
        try? await outbound.write(.text(#"{"type":"task_stream_stopped"}"#))
    }

    /// Push-only notes inbox stream. Diffs the `notes_snapshot`
    /// envelope produced by the unit-tested
    /// `notesStreamSnapshotJSONString` and re-emits only on change;
    /// the inbound side just drains until `{"type":"stop"}` or close.
    private static func notesWS(
        status: String?,
        store: any Notes,
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter
    ) async {
        try? await outbound.write(.text(#"{"type":"notes_stream_started"}"#))
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var last = ""
                while !Task.isCancelled {
                    if let snapshot = notesStreamSnapshotJSONString(store: store, status: status) {
                        if snapshot != last {
                            last = snapshot
                            try? await outbound.write(.text(snapshot))
                        }
                    } else {
                        try? await outbound.write(.text(
                            #"{"type":"notes_stream_error","error":"inbox unavailable"}"#
                        ))
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            group.addTask {
                do {
                    for try await frame in inbound {
                        guard frame.opcode == .text else { continue }
                        let line = String(buffer: frame.data)
                        if Self.isWSStopFrame(line) { break }
                    }
                } catch {
                    // socket closed; sibling task is cancelled below
                }
            }
            await group.next()
            group.cancelAll()
        }
        try? await outbound.write(.text(#"{"type":"notes_stream_stopped"}"#))
    }

    private static func handleReviewTaskWSLine(
        line: String,
        taskStore: any ReviewTaskStore,
        outbound: WebSocketOutboundWriter
    ) async -> Bool {
        guard let data = line.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = dict["type"] as? String else {
            return false
        }
        do {
            let task: ReviewTask?
            switch type {
            case "stop":
                try? await outbound.write(.text(#"{"type":"task_stream_stopped","reason":"client"}"#))
                return true
            case "claim_next":
                guard let agentId = dict["agentId"] as? String else { throw ReviewTaskWSError.missing("agentId") }
                task = try taskStore.claimNext(agentId: agentId)
            case "claim":
                guard let agentId = dict["agentId"] as? String else { throw ReviewTaskWSError.missing("agentId") }
                task = try taskStore.claimTask(id: try requiredString("taskId", dict), agentId: agentId)
            case "event":
                task = try taskStore.appendEvent(
                    taskId: try requiredString("taskId", dict),
                    input: ReviewTaskEventInput(
                        type: (dict["eventType"] as? String) ?? "progress",
                        actor: dict["actor"] as? String,
                        message: try requiredString("message", dict),
                        metadataJSON: dict["metadataJSON"] as? String
                    )
                )
            case "result":
                task = try taskStore.updateTask(
                    id: try requiredString("taskId", dict),
                    input: ReviewTaskUpdateInput(
                        status: (dict["status"] as? String) ?? "readyForVerify",
                        assignee: dict["assignee"] as? String,
                        resultSummary: try requiredString("summary", dict),
                        verificationSnapshotId: dict["verificationSnapshotId"] as? String,
                        notes: dict["notes"] as? String,
                        actor: dict["actor"] as? String
                    )
                )
            case "verify":
                let before = dict["beforeSnapshotIds"] as? [String]
                let verification = ReviewTaskVerification(
                    id: FileReviewStore.makeID(prefix: "verify"),
                    taskId: try requiredString("taskId", dict),
                    beforeSnapshotIds: before ?? [],
                    afterSnapshotId: dict["afterSnapshotId"] as? String,
                    status: (dict["status"] as? String) ?? "pending",
                    notes: dict["notes"] as? String,
                    createdAt: Date()
                )
                task = try taskStore.addVerification(taskId: verification.taskId, verification: verification)
            default:
                return false
            }
            if let task {
                let payload = try jsonEncoder.encode(TaskStreamTask(type: "task_update", task: task))
                try await outbound.write(.text(String(decoding: payload, as: UTF8.self)))
            } else {
                try await outbound.write(.text(#"{"type":"task_update","task":null}"#))
            }
            return true
        } catch {
            try? await outbound.write(.text(
                #"{"type":"task_stream_error","error":"\#(jsonEscape(String(describing: error)))"}"#
            ))
            return true
        }
    }

    private static func isWSStopFrame(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return (dict["type"] as? String) == "stop"
    }

    static func makeReviewBundle(
        input: ReviewBundleInput,
        session: ReviewSession,
        store: any ReviewStore
    ) throws -> ReviewBundle {
        let snapshotIds = Set(input.snapshotIds)
        let commentIds = Set(input.commentIds ?? [])
        let edgeIds = Set(input.edgeIds ?? [])
        let snapshots = session.snapshots.filter { snapshotIds.contains($0.id) }
        let comments = session.comments.filter {
            commentIds.isEmpty ? snapshotIds.contains($0.snapshotId) : commentIds.contains($0.id)
        }
        let edges = session.edges.filter {
            edgeIds.isEmpty
                ? snapshotIds.contains($0.toSnapshotId)
                    || ($0.fromSnapshotId.map { snapshotIds.contains($0) } ?? false)
                : edgeIds.contains($0.id)
        }
        let bundleId = FileReviewStore.makeID(prefix: "bundle")
        let jsonPath = "bundles/\(bundleId)/bundle.json"
        let markdownPath = "bundles/\(bundleId)/brief.md"
        let bundle = ReviewBundle(
            id: bundleId,
            createdAt: Date(),
            snapshotIds: snapshots.map(\.id),
            commentIds: comments.map(\.id),
            edgeIds: edges.map(\.id),
            jsonPath: jsonPath,
            markdownPath: markdownPath
        )
        let payload = ReviewBundlePayload(
            session: session,
            snapshots: snapshots,
            comments: comments,
            edges: edges
        )
        try store.writeArtifact(
            sessionId: session.id,
            relativePath: jsonPath,
            data: try jsonEncoder.encode(payload)
        )
        try store.writeArtifact(
            sessionId: session.id,
            relativePath: markdownPath,
            data: Data(markdownBrief(
                session: session,
                snapshots: snapshots,
                comments: comments,
                edges: edges
            ).utf8)
        )
        return bundle
    }

    /// Pure field-mapping from a decoded create-input to the persisted
    /// `ReviewTask`, split out of `createReviewTask` so it is unit-testable
    /// without a `Request` or a store. Notably threads `input.criteria`
    /// (ADR-0002) onto the task — verification has nothing to check
    /// otherwise — and applies the default title/instructions used when the
    /// operator leaves them blank.
    static func reviewTaskFromCreateInput(
        taskId: String,
        sessionId: String,
        input: ReviewTaskCreateInput,
        bundle: ReviewBundle?,
        contextPath: String,
        elements: [ReviewTaskElement],
        now: Date
    ) -> ReviewTask {
        let title = input.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = input.instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReviewTask(
            id: taskId,
            sessionId: sessionId,
            bundleId: bundle?.id,
            title: title?.isEmpty == false ? title! : "Review selected AX elements",
            instructions: instructions?.isEmpty == false
                ? instructions!
                : "Use the attached review context, screenshot, AX tree, comments, and source references to make the requested UI change and verify it against a fresh capture.",
            status: "open",
            priority: input.priority ?? "normal",
            assignee: input.assignee,
            contextPath: contextPath,
            bundleJSONPath: bundle?.jsonPath,
            bundleMarkdownPath: bundle?.markdownPath,
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
                    actor: input.assignee,
                    message: "Created from review selection",
                    metadataJSON: nil,
                    createdAt: now
                )
            ],
            criteria: input.criteria ?? []
        )
    }

    private static func ensureBundle(
        input: ReviewTaskCreateInput,
        session: inout ReviewSession,
        store: any ReviewStore
    ) throws -> ReviewBundle? {
        if let bundleId = input.bundleId,
           let bundle = session.bundles.first(where: { $0.id == bundleId }) {
            return bundle
        }
        let snapshotIds = input.snapshotIds
        guard !snapshotIds.isEmpty else { return nil }
        let bundle = try makeReviewBundle(
            input: ReviewBundleInput(snapshotIds: snapshotIds, commentIds: nil, edgeIds: nil),
            session: session,
            store: store
        )
        session.bundles.append(bundle)
        return bundle
    }

    private static func taskElements(
        taskId: String,
        input: ReviewTaskCreateInput,
        session: ReviewSession
    ) -> [ReviewTaskElement] {
        (input.elements ?? []).map { item in
            let element = session.snapshots
                .first { $0.id == item.snapshotId }?
                .elements?
                .first { $0.axNodePath == item.axNodePath }
            let comments = session.comments
                .filter { $0.snapshotId == item.snapshotId && $0.axNodePath == item.axNodePath }
                .map(\.text)
                .joined(separator: "\n")
            return ReviewTaskElement(
                id: FileReviewStore.makeID(prefix: "taskel"),
                taskId: taskId,
                snapshotId: item.snapshotId,
                axNodePath: item.axNodePath,
                role: element?.role,
                label: element?.label ?? element?.title ?? element?.value,
                frame: element?.frame,
                commentText: item.commentText ?? (comments.isEmpty ? nil : comments)
            )
        }
    }

    private static func taskContextMarkdown(
        session: ReviewSession,
        bundle: ReviewBundle?,
        snapshotIds: [String],
        elements: [ReviewTaskElement]
    ) -> String {
        var out: [String] = []
        out.append("# Queued review task")
        out.append("")
        out.append("Session: `\(session.id)`")
        if let bundle {
            out.append("Bundle: `\(bundle.id)`")
            out.append("Bundle JSON: `\(bundle.jsonPath)`")
            out.append("Bundle brief: `\(bundle.markdownPath)`")
        }
        out.append("")
        out.append("## Screens")
        for id in snapshotIds {
            guard let snapshot = session.snapshots.first(where: { $0.id == id }) else { continue }
            out.append("- `\(snapshot.id)` on `\(snapshot.udid)`")
            out.append("  - screenshot: `\(snapshot.screenshotPath)`")
            out.append("  - accessibility: `\(snapshot.axPath)`")
        }
        out.append("")
        out.append("## Elements")
        if elements.isEmpty {
            out.append("- No element-level selection supplied.")
        } else {
            for element in elements {
                out.append("- `\(element.snapshotId)` `\(element.axNodePath)` \(element.label ?? element.role ?? "")")
                if let frame = element.frame {
                    out.append("  - frame: x=\(frame.origin.x) y=\(frame.origin.y) w=\(frame.size.width) h=\(frame.size.height)")
                }
                if let comment = element.commentText {
                    out.append("  - comment: \(comment)")
                }
            }
        }
        return out.joined(separator: "\n")
    }

    private static func reviewArtifact(
        id: String,
        path: String,
        store: any ReviewStore
    ) -> Response {
        do {
            let data = try store.readArtifact(sessionId: id, relativePath: path)
            return Response(
                status: .ok,
                headers: [.contentType: contentType(for: path), .cacheControl: "no-cache"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        } catch ReviewStoreError.notFound {
            return errorJSON("missing artifact: \(path)", status: .notFound)
        } catch {
            return errorJSON(String(describing: error), status: .badRequest)
        }
    }

    /// Pull the UDID out of a `/simulators/<udid>/<verb>` request.
    /// `<verb>` is the last segment, `<udid>` the one before.
    private static func udidParam(_ request: Request) -> String {
        let parts = request.uri.path.split(separator: "/")
        guard parts.count >= 3 else { return "" }
        return String(parts[parts.count - 2]).removingPercentEncoding ?? ""
    }

    private static func reviewIdParam(_ request: Request) -> String {
        let parts = request.uri.path.split(separator: "/")
        guard parts.count >= 2 else { return "" }
        return String(parts[1]).removingPercentEncoding ?? ""
    }

    private static func taskIdParam(_ request: Request) -> String {
        let parts = request.uri.path.split(separator: "/")
        guard parts.count >= 2 else { return "" }
        return String(parts[1]).removingPercentEncoding ?? ""
    }

    private static func trailingIDParam(_ request: Request) -> String {
        let parts = request.uri.path.split(separator: "/")
        guard let last = parts.last else { return "" }
        return String(last)
            .replacingOccurrences(of: ".json", with: "")
            .removingPercentEncoding ?? ""
    }

    private static func agentTaskIdParam(_ request: Request) -> String {
        let parts = request.uri.path.split(separator: "/")
        guard parts.count >= 3 else { return "" }
        return String(parts[2]).removingPercentEncoding ?? ""
    }

    private static func flowIdParam(_ request: Request) -> String {
        let parts = request.uri.path.split(separator: "/")
        // path shape: /reviews/:id/flows/:flowId/replay → index 3
        guard parts.count >= 4 else { return "" }
        return String(parts[3]).removingPercentEncoding ?? ""
    }

    private static func requiredString(_ key: String, _ dict: [String: Any]) throws -> String {
        guard let value = dict[key] as? String, !value.isEmpty else {
            throw ReviewTaskWSError.missing(key)
        }
        return value
    }

    private static func redirect(to path: String) -> Response {
        Response(
            status: .found,
            headers: [.location: path],
            body: .init(byteBuffer: ByteBuffer(string: ""))
        )
    }

    /// The trust allowlist the guard consults at request time: the
    /// operator's `--trusted-host` set plus any hostnames a running
    /// tunnel has discovered. A quick tunnel's hostname isn't known
    /// until the child prints it, so it's merged in dynamically rather
    /// than fixed at bind time. Same-origin still has to hold — being
    /// on the allowlist only clears the DNS-rebind guard.
    static func effectiveTrustedHosts(
        static staticHosts: Set<String>,
        dynamic dynamicHosts: Set<String>
    ) -> Set<String> {
        staticHosts.union(dynamicHosts)
    }

    private static func rejectUntrustedBrowserRequest(
        _ request: Request,
        bindHost: String,
        bindPort: Int,
        trustedHosts: Set<String> = []
    ) -> Response? {
        guard !isTrustedBrowserRequest(
            request, bindHost: bindHost, bindPort: bindPort,
            trustedHosts: trustedHosts
        ) else {
            return nil
        }
        return errorJSON("forbidden origin", status: .forbidden)
    }

    /// Browsers can drive localhost services from another site unless the
    /// service checks `Origin`. For a loopback bind, also reject DNS-rebind
    /// style `Host` values that are not loopback names.
    ///
    /// `trustedHosts` is the operator-supplied allowlist (e.g. a Tailscale
    /// MagicDNS name). An allowlisted `Host` bypasses the loopback-only
    /// DNS-rebind guard so a tailnet client can reach a loopback bind, but it
    /// still has to clear the same-origin check below — a cross-site page
    /// served from the trusted name must not be able to drive the simulator.
    static func isTrustedBrowserRequest(
        _ request: Request,
        bindHost: String,
        bindPort: Int,
        trustedHosts: Set<String> = []
    ) -> Bool {
        let allowed = Set(trustedHosts.map { $0.lowercased() })
        let requestHost = request.head.authority
            .flatMap { parseAuthority($0)?.host.lowercased() }
        let isAllowlisted = requestHost.map { allowed.contains($0) } ?? false

        if isLoopbackBind(bindHost), !isAllowlisted,
           let authority = request.head.authority,
           let requestHost = parseAuthority(authority)?.host,
           !isLoopbackHost(requestHost) {
            return false
        }

        if let fetchSite = request.headers[.secFetchSite]?.lowercased(),
           fetchSite == "cross-site" {
            return false
        }

        guard let origin = request.headers[.origin] else { return true }
        guard let originURL = URLComponents(string: origin),
              let originHost = originURL.host else {
            return false
        }

        let authority = request.head.authority ?? "\(bindHost):\(bindPort)"
        guard let requestAuthority = parseAuthority(authority) else { return false }
        let requestPort = requestAuthority.port ?? bindPort
        // A `ws://` / `wss://` Origin is only ever sent by a first-party
        // WebSocket client (`agent-sim connect` via swift-websocket) — a
        // browser carries the page's http(s) Origin for a WS handshake,
        // never a ws-scheme one. That client omits the port, so default
        // a port-less ws/wss Origin to the request port rather than ws's
        // nominal 80/443; the host checks below still gate it.
        let originSchemeIsWebSocket =
            originURL.scheme?.lowercased() == "ws" || originURL.scheme?.lowercased() == "wss"
        let originPort = originURL.port
            ?? (originSchemeIsWebSocket ? requestPort : defaultPort(for: originURL.scheme))

        if isLoopbackBind(bindHost), !isAllowlisted {
            return isLoopbackHost(originHost)
                && isLoopbackHost(requestAuthority.host)
                && (originPort ?? requestPort) == requestPort
        }

        // Same-origin for an allowlisted / non-loopback host. The host
        // match is the cross-origin defence — a page from another site
        // carries a mismatched Origin and is rejected here.
        guard originHost.caseInsensitiveCompare(requestAuthority.host) == .orderedSame else {
            return false
        }
        // Enforce the port too only when the Host header carried one
        // (a direct bind, or a Tailscale URL like `host:8421`). A
        // TLS-terminating tunnel / reverse proxy serves the public name
        // on 443 and forwards a port-less Host that maps to the bind
        // port — there's no port to match, and the host match already
        // established same-origin.
        if let explicitRequestPort = requestAuthority.port {
            return (originPort ?? explicitRequestPort) == explicitRequestPort
        }
        return true
    }

    private static func parseAuthority(_ raw: String) -> (host: String, port: Int?)? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.hasPrefix("["),
           let close = value.firstIndex(of: "]") {
            let host = String(value[value.index(after: value.startIndex)..<close])
            let rest = value[value.index(after: close)...]
            let port = rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil
            return (host, port)
        }

        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 1 { return (String(parts[0]), nil) }
        guard let last = parts.last, let port = Int(last) else { return (value, nil) }
        return (parts.dropLast().joined(separator: ":"), port)
    }

    private static func defaultPort(for scheme: String?) -> Int? {
        switch scheme?.lowercased() {
        case "http", "ws": return 80
        case "https", "wss": return 443
        default: return nil
        }
    }

    private static func isLoopbackBind(_ host: String) -> Bool {
        let lower = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return lower == "localhost" || lower == "::1" || lower.hasPrefix("127.")
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let lower = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return lower == "localhost" || lower == "::1" || lower.hasPrefix("127.")
    }
}

// MARK: - tiny response helpers

private let jsonOK = Response(
    status: .ok,
    headers: [.contentType: "application/json"],
    body: .init(byteBuffer: ByteBuffer(string: "{\"ok\":true}"))
)

private let jsonEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    e.dateEncodingStrategy = .iso8601
    return e
}()

private let jsonDecoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}()

private func jsonResponse(_ data: Data, status: HTTPResponse.Status = .ok) -> Response {
    Response(
        status: status,
        headers: [.contentType: "application/json", .cacheControl: "no-cache"],
        body: .init(byteBuffer: ByteBuffer(data: data))
    )
}

private func errorJSON(_ message: String, status: HTTPResponse.Status) -> Response {
    return Response(
        status: status,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: ByteBuffer(string:
            "{\"ok\":false,\"error\":\"\(jsonEscape(message))\"}"
        ))
    )
}

private func decodeJSON<T: Decodable>(_ type: T.Type, from request: Request) async throws -> T {
    var buffer = try await request.body.collect(upTo: 5_242_880)
    let data = buffer.readData(length: buffer.readableBytes) ?? Data()
    if data.isEmpty, T.self == CreateReviewBody.self {
        return CreateReviewBody(name: nil) as! T
    }
    return try jsonDecoder.decode(T.self, from: data)
}

private struct CreateReviewBody: Codable, Sendable {
    var name: String?
}

private struct ReviewEdgeInput: Codable, Sendable {
    var fromSnapshotId: String?
    var toSnapshotId: String
    var actionType: String
    var axNodePath: String?
    var gestureJSON: String?
}

private struct ReviewBundlePayload: Codable, Sendable {
    var session: ReviewSession
    var snapshots: [ReviewScreenSnapshot]
    var comments: [ReviewElementComment]
    var edges: [ReviewEdge]
}

private struct TaskStreamSnapshot: Codable, Sendable {
    var type = "task_snapshot"
    var tasks: [ReviewTask]
}

private struct TaskStreamTask: Codable, Sendable {
    var type: String
    var task: ReviewTask
}

private struct NotesStreamSnapshot: Codable, Sendable {
    var type = "notes_snapshot"
    var notes: [Note]
}

/// `POST /notes/:id/promote` result: the picked-up note plus the
/// review task it became (`null` only if bulk-create produced none).
private struct NotePromotionResult: Codable, Sendable {
    var note: Note
    var task: ReviewTask?
}

private enum ReviewTaskWSError: Error, CustomStringConvertible {
    case missing(String)

    var description: String {
        switch self {
        case .missing(let key): return "missing \(key)"
        }
    }
}

private func markdownBrief(
    session: ReviewSession,
    snapshots: [ReviewScreenSnapshot],
    comments: [ReviewElementComment],
    edges: [ReviewEdge]
) -> String {
    var out: [String] = []
    out.append("# \(session.name)")
    out.append("")
    out.append("Review session: `\(session.id)`")
    out.append("")
    out.append("## Screens")
    if snapshots.isEmpty {
        out.append("- No snapshots selected.")
    } else {
        for snapshot in snapshots {
            let markers = snapshot.markers.map { $0.kind.rawValue }.joined(separator: ", ")
            out.append("- `\(snapshot.id)` on `\(snapshot.udid)` fingerprint `\(snapshot.screenFingerprint)`\(markers.isEmpty ? "" : " markers: \(markers)")")
            out.append("  - screenshot: `\(snapshot.screenshotPath)`")
            out.append("  - accessibility: `\(snapshot.axPath)`")
        }
    }
    out.append("")
    out.append("## Path")
    if edges.isEmpty {
        out.append("- No path edges selected.")
    } else {
        for edge in edges {
            out.append("- \(edge.actionType): `\(edge.fromSnapshotId ?? "start")` -> `\(edge.toSnapshotId)`")
        }
    }
    out.append("")
    out.append("## Comments")
    if comments.isEmpty {
        out.append("- No comments selected.")
    } else {
        for comment in comments {
            let frame: String
            if let rect = comment.frame {
                frame = " frame x:\(Int(rect.origin.x)) y:\(Int(rect.origin.y)) w:\(Int(rect.size.width)) h:\(Int(rect.size.height))"
            } else {
                frame = ""
            }
            out.append("- `\(comment.snapshotId)` `\(comment.axNodePath)`\(frame): \(comment.text)")
        }
    }
    out.append("")
    return out.joined(separator: "\n")
}

/// Plain-old-data carrier for the `/simulators/:udid/logs` query
/// string + path UDID. Pulled into its own struct so the route
/// closure stays a one-liner — Hummingbird's router-builder
/// inference deteriorates fast when the closure body argues with
/// 8-parameter calls inline.
private struct LogsRouteOptions: Sendable {
    let udid: String
    let level: String
    let style: String
    let predicate: String?
    let bundleId: String?

    static func from(request: Request) -> LogsRouteOptions {
        let parts = request.uri.path.split(separator: "/")
        var udid = ""
        if parts.count >= 3 {
            udid = String(parts[parts.count - 2]).removingPercentEncoding ?? ""
        }
        let q = request.uri.queryParameters
        let level: String     = q.get("level").map { String($0) }     ?? "info"
        let style: String     = q.get("style").map { String($0) }     ?? "default"
        let predicate: String? = q.get("predicate").map { String($0) }
        let bundleId: String?  = q.get("bundleId").map { String($0) }
        return LogsRouteOptions(
            udid: udid,
            level: level,
            style: style,
            predicate: predicate,
            bundleId: bundleId
        )
    }
}

/// Minimal JSON-string escaper: backslash, quote, and the ASCII
/// control characters that JSON forbids unescaped. Sufficient for
/// embedding a log line into a `{"line":"…"}` envelope without
/// rebuilding the whole dict via JSONSerialization.
private func jsonEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count + 8)
    for ch in s.unicodeScalars {
        switch ch {
        case "\"":  out.append("\\\"")
        case "\\":  out.append("\\\\")
        case "\n":  out.append("\\n")
        case "\r":  out.append("\\r")
        case "\t":  out.append("\\t")
        case "\u{08}": out.append("\\b")
        case "\u{0C}": out.append("\\f")
        default:
            if ch.value < 0x20 {
                out.append(String(format: "\\u%04x", ch.value))
            } else {
                out.append(Character(ch))
            }
        }
    }
    return out
}

/// Build the `{"type":"log","lines":[…]}` envelope for one drained
/// `LogBatcher` batch. Hand-rolled rather than going through
/// `JSONSerialization` because the hot path runs at most ~20×/sec
/// per logs WS and each entry is already a UTF-8 string we can
/// escape in place.
private func envelope(forBatch lines: [String]) -> String {
    var s = #"{"type":"log","lines":["#
    for (i, line) in lines.enumerated() {
        if i > 0 { s.append(",") }
        s.append("\"")
        s.append(jsonEscape(line))
        s.append("\"")
    }
    s.append("]}")
    return s
}

private func contentType(for filename: String) -> String {
    if filename.hasSuffix(".html") { return "text/html; charset=utf-8" }
    if filename.hasSuffix(".js")   { return "application/javascript; charset=utf-8" }
    if filename.hasSuffix(".css")  { return "text/css; charset=utf-8" }
    if filename.hasSuffix(".json") { return "application/json; charset=utf-8" }
    if filename.hasSuffix(".png")  { return "image/png" }
    if filename.hasSuffix(".jpg") || filename.hasSuffix(".jpeg") { return "image/jpeg" }
    if filename.hasSuffix(".webm") { return "video/webm" }
    if filename.hasSuffix(".mp4")  { return "video/mp4" }
    return "application/octet-stream"
}

private extension HTTPField.Name {
    static let secFetchSite = Self("Sec-Fetch-Site")!
    static let contentSecurityPolicy = Self("Content-Security-Policy")!
}
