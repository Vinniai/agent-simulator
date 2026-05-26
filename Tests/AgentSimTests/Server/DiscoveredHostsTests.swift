import Testing
@testable import AgentSim

/// `DiscoveredHosts` is the live channel between a running `HostTunnel`
/// and the server's trust guard: the tunnel's public hostname isn't
/// known at bind time, so the child's `onURL` callback drops it in here
/// and the guard reads the current snapshot on every request. The box
/// is the only mutable state shared across the NIO event loops and the
/// tunnel's callback thread, so it has to be a set with race-free
/// insert / read.
@Suite("DiscoveredHosts — live tunnel trust channel")
struct DiscoveredHostsTests {

    @Test func `starts empty`() {
        #expect(DiscoveredHosts().current().isEmpty)
    }

    @Test func `an inserted host shows up in the snapshot`() {
        let hosts = DiscoveredHosts()
        hosts.insert("flat-mode-coral.trycloudflare.com")
        #expect(hosts.current() == ["flat-mode-coral.trycloudflare.com"])
    }

    @Test func `inserting the same host twice keeps the set unique`() {
        let hosts = DiscoveredHosts()
        hosts.insert("flat-mode-coral.trycloudflare.com")
        hosts.insert("flat-mode-coral.trycloudflare.com")
        #expect(hosts.current().count == 1)
    }

    @Test func `distinct hosts accumulate`() {
        let hosts = DiscoveredHosts()
        hosts.insert("one.trycloudflare.com")
        hosts.insert("two.ngrok-free.app")
        #expect(hosts.current() == ["one.trycloudflare.com", "two.ngrok-free.app"])
    }
}
