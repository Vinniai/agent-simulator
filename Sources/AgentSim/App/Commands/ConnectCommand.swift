import ArgumentParser
import Foundation
import HummingbirdWSClient
import Logging
import NIOCore

/// `agent-simulator connect <url> --udid <id> [--tap X,Y] [--size WxH]
///  [--format mjpeg] [--seconds 3]`
///
/// The other end of the Mac-mini-at-home → Claude-on-the-web story:
/// from a *remote* machine, dial a running `agent-simulator serve`, confirm
/// frames are actually flowing (downstream), and optionally fire one
/// tap (upstream) to prove the gesture channel — a two-way smoke test.
///
/// The URL is the same base the operator would open in a browser
/// (`http://mini.local:8421`, or a tunnel's `https://…`); the WS stream
/// route is derived by `RemoteEndpoint`. The verdict — frames / fps /
/// bytes-per-frame — is `ConnectReport`. Both are pure value types,
/// unit-tested; this command is just the irreducible socket plumbing.
struct ConnectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "connect",
        abstract: "Connect to a remote agent-simulator serve and smoke-test its stream"
    )

    @Argument(help: "Base URL of the remote serve (e.g. http://mini.local:8421 or a tunnel https URL)")
    var url: String

    @Option(name: .long, help: "UDID of the remote simulator to stream")
    var udid: String

    @Option(name: .long, help: "Fire one tap at \"X,Y\" device points to prove the upstream channel")
    var tap: String?

    @Option(name: .long, help: "Device size in points \"WxH\" the --tap coordinates are relative to")
    var size: String = "393x852"

    @Option(name: .long, help: "Stream format to request: avcc | mjpeg")
    var format: String = "avcc"

    @Option(name: .long, help: "Sampling window (seconds) to count frames over")
    var seconds: Double = 3

    func run() async throws {
        guard let endpoint = RemoteEndpoint.stream(base: url, udid: udid, format: format) else {
            log("connect: invalid URL '\(url)'")
            Foundation.exit(1)
        }

        var pendingTap: RemoteTap?
        if let tap {
            guard let parsed = RemoteTap.parse(point: tap, size: size) else {
                log("connect: invalid --tap '\(tap)' / --size '\(size)' (want X,Y and WxH)")
                Foundation.exit(1)
            }
            pendingTap = parsed
        }

        log("connecting to \(endpoint.webSocketURL) …")
        let report = try await Self.smokeTest(
            url: endpoint.webSocketURL,
            tap: pendingTap,
            seconds: seconds
        )

        if let pendingTap {
            log("sent tap \(Int(pendingTap.x)),\(Int(pendingTap.y))")
        }
        log(report.summary)
        if report.ok {
            log("handshake ok — stream is live")
        } else {
            log("no frames received — stream did not start")
            Foundation.exit(1)
        }
    }

    /// Integration-only. Dial the WebSocket, count binary frames over
    /// the window, and (if asked) send one tap up the same socket. All
    /// the value-logic (URL, envelope, verdict) is in the Domain types;
    /// this is the irreducible network plumbing.
    private static func smokeTest(
        url: String, tap: RemoteTap?, seconds: Double
    ) async throws -> ConnectReport {
        let tally = FrameTally()
        let logger = Logger(label: "agent-simulator.connect")

        // The default client frame ceiling is 16 KiB — far below a single
        // AVCC seed / H.264 keyframe (often 100 KiB+). Left at the default
        // the client rejects the first big frame as a protocol violation
        // and closes, so *nothing* is ever counted. Raise it to 16 MiB,
        // matching what the server is happy to emit.
        let config = WebSocketClientConfiguration(maxFrameSize: 16 << 20)

        // Bound the sampling window from *outside* the WebSocket handler:
        // race the whole connection against a timer in a plain task group.
        // When the window elapses, cancelling the group tears the socket
        // down and the handler's `for await` loop unwinds. The handler body
        // stays a simple sequential read — no inner task, no inner sleep.
        //
        // Use `Task.sleep(nanoseconds:)`, not the `Clock`-based
        // `Task.sleep(for:)`: the latter's specialization mismanages the
        // task allocator under release optimization and aborts with "freed
        // pointer was not the last allocation".
        let windowNanos = UInt64(max(0, seconds) * 1_000_000_000)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await WebSocketClient.connect(url: url, configuration: config, logger: logger) {
                    inbound, outbound, _ in
                    // Prove the upstream direction first so a tap is in
                    // flight while we sample the downstream frames.
                    if let tap {
                        try await outbound.write(.text(tap.wireJSON))
                    }
                    for try await frame in inbound where frame.opcode == .binary {
                        await tally.add(bytes: frame.data.readableBytes)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: windowNanos)
            }
            // The timer finishes first on a live stream; if the server
            // closes early the connect task finishes first. Either way,
            // take the first result and cancel the rest.
            _ = try? await group.next()
            group.cancelAll()
        }

        let snapshot = await tally.snapshot()
        return ConnectReport(frames: snapshot.frames, bytes: snapshot.bytes, seconds: seconds)
    }
}

/// Thread-safe running totals for the binary frames seen during a
/// `connect` smoke test.
private actor FrameTally {
    private var frames = 0
    private var bytes = 0
    func add(bytes: Int) {
        frames += 1
        self.bytes += bytes
    }
    func snapshot() -> (frames: Int, bytes: Int) { (frames, bytes) }
}
