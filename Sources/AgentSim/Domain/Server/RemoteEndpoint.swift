import Foundation

/// The stream WebSocket URL for a *remote* `agent-simulator serve` — the
/// other half of the Mac-mini-at-home → Claude-on-the-web story. The
/// operator pastes the same base URL they'd open in a browser
/// (`http://mini.local:8421`, or a tunnel's `https://…`); this derives
/// the `/simulators/<udid>/stream` WebSocket route the `connect`
/// command dials.
///
/// Pure string surgery: the scheme flips to its WS counterpart
/// (http→ws, https→wss; ws/wss pass through), a missing scheme is
/// assumed to be plaintext http, and host + port are preserved verbatim
/// via `URLComponents`.
struct RemoteEndpoint: Equatable, Sendable {
    let webSocketURL: String

    static func stream(base: String, udid: String, format: String = "mjpeg") -> RemoteEndpoint? {
        // A bare `host:port` (no scheme) is the friendly common case —
        // treat it as plaintext http rather than refusing it.
        let normalized = base.contains("://") ? base : "http://\(base)"
        guard var comps = URLComponents(string: normalized) else { return nil }

        let wsScheme: String
        switch comps.scheme?.lowercased() {
        case "http", "ws":   wsScheme = "ws"
        case "https", "wss": wsScheme = "wss"
        default:             return nil
        }
        guard let host = comps.host, !host.isEmpty else { return nil }

        comps.scheme = wsScheme
        comps.path = "/simulators/\(udid)/stream"
        comps.query = "format=\(format)"
        guard let url = comps.url else { return nil }
        return RemoteEndpoint(webSocketURL: url.absoluteString)
    }
}
