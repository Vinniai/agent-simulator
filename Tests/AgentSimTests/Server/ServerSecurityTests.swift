import Testing
import Hummingbird
import HTTPTypes
import NIOCore
@testable import AgentSim

@Suite("Server browser security")
struct ServerSecurityTests {

    @Test func `allows direct loopback requests without an Origin header`() {
        let request = Self.request(host: "127.0.0.1:8421")

        #expect(Server.isTrustedBrowserRequest(
            request, bindHost: "127.0.0.1", bindPort: 8421
        ))
    }

    @Test func `allows same-origin browser requests on loopback`() {
        let request = Self.request(
            host: "localhost:8421",
            origin: "http://localhost:8421"
        )

        #expect(Server.isTrustedBrowserRequest(
            request, bindHost: "127.0.0.1", bindPort: 8421
        ))
    }

    @Test func `rejects cross-site browser requests to loopback control routes`() {
        let request = Self.request(
            host: "127.0.0.1:8421",
            origin: "https://example.test"
        )

        #expect(!Server.isTrustedBrowserRequest(
            request, bindHost: "127.0.0.1", bindPort: 8421
        ))
    }

    @Test func `rejects DNS rebind shaped hosts on loopback binds`() {
        let request = Self.request(
            host: "attacker.test:8421",
            origin: "http://attacker.test:8421"
        )

        #expect(!Server.isTrustedBrowserRequest(
            request, bindHost: "127.0.0.1", bindPort: 8421
        ))
    }

    @Test func `accepts a first-party WebSocket client Origin on a loopback bind`() {
        // `agent-sim connect` (swift-websocket) sends a port-less
        // `ws://` Origin — never a shape a browser produces — so the
        // port must default to the request port, not ws's default 80.
        let request = Self.request(
            host: "127.0.0.1:8421",
            origin: "ws://127.0.0.1"
        )

        #expect(Server.isTrustedBrowserRequest(
            request, bindHost: "127.0.0.1", bindPort: 8421
        ))
    }

    @Test func `accepts a first-party WebSocket client Origin on a LAN bind`() {
        let request = Self.request(
            host: "192.168.1.9:8421",
            origin: "ws://192.168.1.9"
        )

        #expect(Server.isTrustedBrowserRequest(
            request, bindHost: "192.168.1.9", bindPort: 8421
        ))
    }

    @Test func `rejects a WebSocket Origin whose host differs on loopback`() {
        let request = Self.request(
            host: "127.0.0.1:8421",
            origin: "ws://attacker.test"
        )

        #expect(!Server.isTrustedBrowserRequest(
            request, bindHost: "127.0.0.1", bindPort: 8421
        ))
    }

    @Test func `rejects Fetch Metadata cross-site requests`() {
        let request = Self.request(
            host: "127.0.0.1:8421",
            origin: "http://127.0.0.1:8421",
            fetchSite: "cross-site"
        )

        #expect(!Server.isTrustedBrowserRequest(
            request, bindHost: "127.0.0.1", bindPort: 8421
        ))
    }

    @Test func `static asset responses deny foreign framing`() {
        let csp = HTTPField.Name("Content-Security-Policy")!

        for asset in ["sim.html", "farm/farm.html"] {
            let response = Server.staticAsset(asset)

            #expect(response.headers[csp] == "frame-ancestors 'none'")
        }
    }

    private static func request(
        host: String,
        origin: String? = nil,
        fetchSite: String? = nil
    ) -> Request {
        var headers: HTTPFields = [:]
        if let origin { headers[.origin] = origin }
        if let fetchSite { headers[HTTPField.Name("Sec-Fetch-Site")!] = fetchSite }

        let head = HTTPRequest(
            method: .post,
            scheme: nil,
            authority: host,
            path: "/simulators/UDID/boot",
            headerFields: headers
        )
        return Request(head: head, body: .init(buffer: ByteBuffer()))
    }
}
