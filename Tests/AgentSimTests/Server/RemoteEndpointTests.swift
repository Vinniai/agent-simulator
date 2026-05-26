import Testing
@testable import AgentSim

/// `RemoteEndpoint` turns the user-facing base URL of a remote
/// `agent-sim serve` (the thing they'd paste into a browser) into the
/// stream WebSocket URL the `connect` command dials. The scheme flips
/// to its WS counterpart (http→ws, https→wss) and the canonical
/// `/simulators/<udid>/stream` route is appended — all pure string
/// work, no socket involved.
@Suite("RemoteEndpoint — remote stream URL derivation")
struct RemoteEndpointTests {

    @Test func `http base becomes a ws stream URL`() {
        let endpoint = RemoteEndpoint.stream(base: "http://127.0.0.1:8421", udid: "ABC")
        #expect(endpoint?.webSocketURL == "ws://127.0.0.1:8421/simulators/ABC/stream?format=mjpeg")
    }

    @Test func `https base becomes a wss stream URL`() {
        let endpoint = RemoteEndpoint.stream(base: "https://x.trycloudflare.com", udid: "ABC")
        #expect(endpoint?.webSocketURL == "wss://x.trycloudflare.com/simulators/ABC/stream?format=mjpeg")
    }

    @Test func `a trailing slash on the base is ignored`() {
        let endpoint = RemoteEndpoint.stream(base: "http://host:8421/", udid: "ABC")
        #expect(endpoint?.webSocketURL == "ws://host:8421/simulators/ABC/stream?format=mjpeg")
    }

    @Test func `a bare host:port defaults to ws`() {
        let endpoint = RemoteEndpoint.stream(base: "192.168.1.9:8421", udid: "ABC")
        #expect(endpoint?.webSocketURL == "ws://192.168.1.9:8421/simulators/ABC/stream?format=mjpeg")
    }

    @Test func `the format is overridable`() {
        let endpoint = RemoteEndpoint.stream(base: "http://h:8421", udid: "ABC", format: "h264")
        #expect(endpoint?.webSocketURL == "ws://h:8421/simulators/ABC/stream?format=h264")
    }

    @Test func `a non-http scheme is rejected`() {
        #expect(RemoteEndpoint.stream(base: "ftp://h:8421", udid: "ABC") == nil)
    }
}
