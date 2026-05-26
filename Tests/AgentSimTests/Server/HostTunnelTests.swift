import Testing
import Foundation
import Mockable
@testable import AgentSim

/// State-machine tests for `HostTunnel`, driven entirely through a
/// `MockSubprocess`. Coverage scope: argv plumbing, the one-shot URL
/// discovery from the child's output, and exit / stop handling. The
/// real `Foundation.Process` spawn lives behind the `Subprocess`
/// collaborator and is integration-only.
@Suite("HostTunnel — orchestration via Subprocess")
struct HostTunnelTests {

    /// Captures the closures `subprocess.run(...)` was handed so the
    /// test can fire them on demand.
    final class Captures: @unchecked Sendable {
        var executable: URL?
        var arguments: [String]?
        var onBytes:   (@Sendable (Data) -> Void)?
        var onExit:    (@Sendable (Int32) -> Void)?
    }

    final class Recorder<T>: @unchecked Sendable {
        var values: [T] = []
        var fireCount: Int { values.count }
        func record(_ v: T) { values.append(v) }
    }

    private func makeTunnel(
        provider: Tunnel.Provider = .cloudflare,
        port: Int = 8421
    ) -> (HostTunnel, MockSubprocess, Captures) {
        let sub = MockSubprocess()
        let captures = Captures()
        given(sub).run(
            executable: .any, arguments: .any,
            onBytes: .any, onExit: .any
        ).willProduce { exe, args, onBytes, onExit in
            captures.executable = exe
            captures.arguments  = args
            captures.onBytes    = onBytes
            captures.onExit     = onExit
        }
        given(sub).terminate().willReturn()
        let host = HostTunnel(
            tunnel: Tunnel(provider: provider, localPort: port),
            subprocess: sub
        )
        return (host, sub, captures)
    }

    // MARK: - argv plumbing

    @Test func `start launches the provider executable via env with its argv`() throws {
        let (host, _, captures) = makeTunnel(provider: .cloudflare, port: 8421)
        try host.start(onURL: { _ in }, onExit: { _ in })
        #expect(captures.executable?.path == "/usr/bin/env")
        #expect(captures.arguments == ["cloudflared", "tunnel", "--url", "http://127.0.0.1:8421"])
    }

    // MARK: - URL discovery

    @Test func `the public URL is surfaced from the first matching line`() throws {
        let (host, _, captures) = makeTunnel()
        let urls = Recorder<URL>()
        try host.start(onURL: { urls.record($0) }, onExit: { _ in })
        captures.onBytes?(Data("2026-05-25 INF Starting tunnel\n".utf8))
        #expect(urls.values.isEmpty)
        captures.onBytes?(Data("|  https://flat-mode-coral.trycloudflare.com  |\n".utf8))
        #expect(urls.values == [URL(string: "https://flat-mode-coral.trycloudflare.com")!])
    }

    @Test func `a banner split across byte chunks still yields the URL`() throws {
        let (host, _, captures) = makeTunnel()
        let urls = Recorder<URL>()
        try host.start(onURL: { urls.record($0) }, onExit: { _ in })
        captures.onBytes?(Data("|  https://flat-mode".utf8))
        #expect(urls.values.isEmpty)
        captures.onBytes?(Data("-coral.trycloudflare.com  |\n".utf8))
        #expect(urls.values == [URL(string: "https://flat-mode-coral.trycloudflare.com")!])
    }

    @Test func `onURL fires exactly once even when later lines carry a URL`() throws {
        let (host, _, captures) = makeTunnel()
        let urls = Recorder<URL>()
        try host.start(onURL: { urls.record($0) }, onExit: { _ in })
        captures.onBytes?(Data("|  https://one.trycloudflare.com  |\n".utf8))
        captures.onBytes?(Data("|  https://two.trycloudflare.com  |\n".utf8))
        #expect(urls.fireCount == 1)
        #expect(urls.values.first == URL(string: "https://one.trycloudflare.com"))
    }

    // MARK: - exit handling

    @Test func `child exit with code zero surfaces nil through onExit`() throws {
        let (host, _, captures) = makeTunnel()
        let exits = Recorder<Error?>()
        try host.start(onURL: { _ in }, onExit: { exits.record($0) })
        captures.onExit?(0)
        #expect(exits.fireCount == 1)
        #expect(exits.values.first ?? Optional<Error>.none == nil)
    }

    @Test func `child exit with non-zero code surfaces nonZeroExit`() throws {
        let (host, _, captures) = makeTunnel()
        let exits = Recorder<Error?>()
        try host.start(onURL: { _ in }, onExit: { exits.record($0) })
        captures.onExit?(7)
        #expect((exits.values.first.flatMap { $0 } as? TunnelError) == .nonZeroExit(code: 7))
    }

    // MARK: - lifecycle

    @Test func `stop terminates the subprocess and drops the follow-up exit`() throws {
        let (host, sub, captures) = makeTunnel()
        let exits = Recorder<Error?>()
        try host.start(onURL: { _ in }, onExit: { exits.record($0) })
        host.stop()
        verify(sub).terminate().called(1)
        captures.onExit?(0) // child dying from SIGTERM must not re-fire onExit
        #expect(exits.fireCount == 0)
    }

    @Test func `start twice throws alreadyStarted`() throws {
        let (host, _, _) = makeTunnel()
        try host.start(onURL: { _ in }, onExit: { _ in })
        #expect(throws: TunnelError.alreadyStarted) {
            try host.start(onURL: { _ in }, onExit: { _ in })
        }
    }
}
