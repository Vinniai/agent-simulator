import Testing
import Foundation
@testable import AgentSim

/// Unit tests for the `Tunnel` value type — the pure description of
/// how to expose a loopback `agent-sim serve` over a public ingress
/// (cloudflared / ngrok): which executable to run, its argv, and how
/// to read the advertised public URL back out of the child's output.
///
/// No process is spawned here; the actual launch lives behind the
/// `Subprocess` collaborator and is exercised in `HostTunnel`'s
/// orchestration tests.
@Suite("Tunnel — provider argv + URL parsing")
struct TunnelTests {

    // MARK: - executable + argv

    @Test func `cloudflare tunnel runs cloudflared against the loopback port`() {
        let tunnel = Tunnel(provider: .cloudflare, localPort: 8421)
        #expect(tunnel.executable == "cloudflared")
        #expect(tunnel.arguments == ["tunnel", "--url", "http://127.0.0.1:8421"])
    }

    @Test func `ngrok tunnel runs ngrok with machine-parseable logging`() {
        let tunnel = Tunnel(provider: .ngrok, localPort: 9000)
        #expect(tunnel.executable == "ngrok")
        #expect(tunnel.arguments == ["http", "9000", "--log=stdout", "--log-format=logfmt"])
    }

    // MARK: - public URL parsing

    @Test func `cloudflare reads its public URL from the banner line`() {
        let tunnel = Tunnel(provider: .cloudflare, localPort: 8421)
        let line = "|  https://flat-mode-coral-xyz.trycloudflare.com                       |"
        #expect(tunnel.publicURL(in: line)
            == URL(string: "https://flat-mode-coral-xyz.trycloudflare.com"))
    }

    @Test func `cloudflare ignores lines without a trycloudflare URL`() {
        let tunnel = Tunnel(provider: .cloudflare, localPort: 8421)
        #expect(tunnel.publicURL(in: "2026-05-25T10:00:00Z INF Starting tunnel") == nil)
        #expect(tunnel.publicURL(in: "+----------------------------------+") == nil)
    }

    @Test func `ngrok reads its public URL from the logfmt url field`() {
        let tunnel = Tunnel(provider: .ngrok, localPort: 8421)
        let line = #"t=2026-05-25T10:00:00 lvl=info msg="started tunnel" url=https://ab12cd.ngrok-free.app"#
        #expect(tunnel.publicURL(in: line)
            == URL(string: "https://ab12cd.ngrok-free.app"))
    }

    @Test func `a provider only matches its own ingress domain`() {
        let ngrok = Tunnel(provider: .ngrok, localPort: 8421)
        // A cloudflare URL must not satisfy the ngrok parser.
        #expect(ngrok.publicURL(in: "url=https://x.trycloudflare.com") == nil)

        let cf = Tunnel(provider: .cloudflare, localPort: 8421)
        #expect(cf.publicURL(in: "url=https://x.ngrok-free.app") == nil)
    }

    // MARK: - provider parsing from the CLI flag

    @Test func `provider parses from its flag spelling and rejects unknowns`() {
        #expect(Tunnel.Provider(rawValue: "cloudflare") == .cloudflare)
        #expect(Tunnel.Provider(rawValue: "ngrok") == .ngrok)
        #expect(Tunnel.Provider(rawValue: "wireguard") == nil)
    }
}
