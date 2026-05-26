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

    // MARK: - dynamic (tunnel-discovered) hosts

    /// A quick tunnel's public hostname isn't known until the child
    /// prints it, so it can't be a `--trusted-host` at bind time. The
    /// running `HostTunnel` feeds it in dynamically; the guard consults
    /// the union of the operator's allowlist and the discovered hosts.
    @Test func `effective allowlist merges operator config with tunnel-discovered hosts`() {
        #expect(
            Server.effectiveTrustedHosts(
                static: ["mac.tailnet.ts.net"],
                dynamic: ["flat-mode-coral.trycloudflare.com"]
            ) == ["mac.tailnet.ts.net", "flat-mode-coral.trycloudflare.com"]
        )
    }

    /// A TLS-terminating tunnel serves the public name on 443 and
    /// forwards a port-less `Host`, mapping 443 → the bind port. The
    /// same-origin check must accept that on a host match rather than
    /// demanding the (absent) Host port equal the bind port.
    @Test func `a tunnel-discovered host is trusted for a same-origin request`() {
        let request = Self.request(
            host: "flat-mode-coral.trycloudflare.com",
            origin: "https://flat-mode-coral.trycloudflare.com"
        )

        #expect(Server.isTrustedBrowserRequest(
            request, bindHost: "127.0.0.1", bindPort: 8421,
            trustedHosts: Server.effectiveTrustedHosts(
                static: [], dynamic: ["flat-mode-coral.trycloudflare.com"]
            )
        ))
    }

    /// Relaxing the port match for port-less proxied hosts must not
    /// open a cross-origin hole: a page served from another site is
    /// still rejected on the host mismatch.
    @Test func `a cross-site origin is rejected even when the proxied Host omits a port`() {
        let request = Self.request(
            host: "flat-mode-coral.trycloudflare.com",
            origin: "https://evil.example.com"
        )

        #expect(!Server.isTrustedBrowserRequest(
            request, bindHost: "127.0.0.1", bindPort: 8421,
            trustedHosts: ["flat-mode-coral.trycloudflare.com"]
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
