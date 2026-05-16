import Testing
import Hummingbird
import HTTPTypes
import NIOCore
@testable import AgentSim

/// `--trusted-host` lets the server be reached over a private mesh
/// (Tailscale / VPN) while still bound to loopback. The MagicDNS name
/// (e.g. `mac.tailnet.ts.net`) is not a loopback host, so without an
/// explicit allowlist the DNS-rebind guard 403s every tailnet request.
/// An allowlisted host bypasses that guard but still has to be
/// same-origin — a cross-site page served from the trusted name must
/// not be able to drive the simulator.
@Suite("Server trusted-host allowlist")
struct TrustedHostTests {

    @Test func `allowlisted host is trusted for a top-level nav on a loopback bind`() {
        let request = Self.request(host: "mac.tailnet.ts.net:8421")

        #expect(Server.isTrustedBrowserRequest(
            request, bindHost: "127.0.0.1", bindPort: 8421,
            trustedHosts: ["mac.tailnet.ts.net"]
        ))
    }

    @Test func `allowlisted host is trusted for a same-origin fetch or WS upgrade`() {
        let request = Self.request(
            host: "mac.tailnet.ts.net:8421",
            origin: "http://mac.tailnet.ts.net:8421"
        )

        #expect(Server.isTrustedBrowserRequest(
            request, bindHost: "127.0.0.1", bindPort: 8421,
            trustedHosts: ["mac.tailnet.ts.net"]
        ))
    }

    @Test func `allowlist match is case-insensitive`() {
        let request = Self.request(host: "MAC.Tailnet.TS.net:8421")

        #expect(Server.isTrustedBrowserRequest(
            request, bindHost: "127.0.0.1", bindPort: 8421,
            trustedHosts: ["mac.tailnet.ts.net"]
        ))
    }

    @Test func `an unconfigured host is still rejected on a loopback bind`() {
        let request = Self.request(host: "evil.example.com:8421")

        #expect(!Server.isTrustedBrowserRequest(
            request, bindHost: "127.0.0.1", bindPort: 8421,
            trustedHosts: ["mac.tailnet.ts.net"]
        ))
    }

    @Test func `a cross-site origin is rejected even from the trusted host`() {
        let request = Self.request(
            host: "mac.tailnet.ts.net:8421",
            origin: "https://evil.example.com"
        )

        #expect(!Server.isTrustedBrowserRequest(
            request, bindHost: "127.0.0.1", bindPort: 8421,
            trustedHosts: ["mac.tailnet.ts.net"]
        ))
    }

    @Test func `empty allowlist preserves the existing loopback behaviour`() {
        let request = Self.request(host: "mac.tailnet.ts.net:8421")

        #expect(!Server.isTrustedBrowserRequest(
            request, bindHost: "127.0.0.1", bindPort: 8421,
            trustedHosts: []
        ))
    }

    // MARK: -

    private static func request(
        host: String,
        origin: String? = nil,
        fetchSite: String? = nil
    ) -> Request {
        var headers: HTTPFields = [:]
        if let origin { headers[.origin] = origin }
        if let fetchSite { headers[HTTPField.Name("Sec-Fetch-Site")!] = fetchSite }

        let head = HTTPRequest(
            method: .get,
            scheme: nil,
            authority: host,
            path: "/m/UDID",
            headerFields: headers
        )
        return Request(head: head, body: .init(buffer: ByteBuffer()))
    }
}
