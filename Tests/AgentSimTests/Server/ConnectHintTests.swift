import Testing
@testable import AgentSim

/// `ConnectHint` renders the copy-pasteable `agent-simulator connect …` line
/// that `serve` prints at startup so a remote device knows exactly how
/// to dial in. A loopback bind isn't reachable off-box, so the hint
/// prefers a discovered LAN address for the host the remote should use.
@Suite("ConnectHint — remote connect invitation")
struct ConnectHintTests {

    @Test func `renders connect with a udid`() {
        #expect(
            ConnectHint.line(base: "http://192.168.1.9:8421", udid: "ABC")
                == "agent-simulator connect http://192.168.1.9:8421 --udid ABC"
        )
    }

    @Test func `omits --udid when no simulator is known`() {
        #expect(
            ConnectHint.line(base: "http://192.168.1.9:8421", udid: nil)
                == "agent-simulator connect http://192.168.1.9:8421"
        )
    }

    @Test func `a loopback bind prefers the discovered LAN address`() {
        #expect(ConnectHint.reachableHost(bind: "127.0.0.1", lan: "192.168.1.9") == "192.168.1.9")
    }

    @Test func `a loopback bind with no LAN address falls back to the bind host`() {
        #expect(ConnectHint.reachableHost(bind: "127.0.0.1", lan: nil) == "127.0.0.1")
    }

    @Test func `a routable bind host is shown as-is`() {
        #expect(ConnectHint.reachableHost(bind: "192.168.1.50", lan: "192.168.1.9") == "192.168.1.50")
    }

    @Test func `a wildcard bind prefers the discovered LAN address`() {
        // 0.0.0.0 / :: mean "all interfaces" — undialable from a remote
        // device, exactly like loopback. Substitute the LAN address.
        #expect(ConnectHint.reachableHost(bind: "0.0.0.0", lan: "192.168.1.9") == "192.168.1.9")
        #expect(ConnectHint.reachableHost(bind: "::", lan: "192.168.1.9") == "192.168.1.9")
        #expect(ConnectHint.reachableHost(bind: "[::]", lan: "192.168.1.9") == "192.168.1.9")
    }

    @Test func `a wildcard bind with no LAN address falls back to the bind host`() {
        #expect(ConnectHint.reachableHost(bind: "0.0.0.0", lan: nil) == "0.0.0.0")
    }

    @Test func `loopback detection covers the usual spellings`() {
        #expect(ConnectHint.isLoopback("127.0.0.1"))
        #expect(ConnectHint.isLoopback("::1"))
        #expect(ConnectHint.isLoopback("localhost"))
        #expect(ConnectHint.isLoopback("LocalHost"))
        #expect(!ConnectHint.isLoopback("192.168.1.9"))
    }

    @Test func `wildcard detection covers v4 and v6 spellings`() {
        #expect(ConnectHint.isWildcard("0.0.0.0"))
        #expect(ConnectHint.isWildcard("::"))
        #expect(ConnectHint.isWildcard("[::]"))
        #expect(!ConnectHint.isWildcard("192.168.1.9"))
        #expect(!ConnectHint.isWildcard("127.0.0.1"))
    }
}
