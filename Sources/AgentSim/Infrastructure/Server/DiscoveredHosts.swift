import Foundation

/// A race-free, growing set of hostnames discovered at runtime by a
/// running `HostTunnel`. A quick tunnel's public name isn't known until
/// the child prints it, so it can't be passed as `--trusted-host` at
/// bind time; instead the tunnel's `onURL` callback `insert`s it here
/// and the server's trust guard reads `current()` on every request
/// (via `Server.dynamicTrustedHosts`).
///
/// Writes come from the tunnel's callback thread; reads come from the
/// NIO event loops handling requests — so the set is guarded by a lock.
final class DiscoveredHosts: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: Set<String> = []

    init() {}

    func insert(_ host: String) {
        lock.lock()
        defer { lock.unlock() }
        hosts.insert(host)
    }

    func current() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return hosts
    }
}
