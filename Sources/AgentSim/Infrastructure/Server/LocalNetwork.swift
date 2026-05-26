import Foundation

/// Best-effort discovery of this Mac's LAN IPv4 address, used to fill in
/// the `serve` startup connect hint when the bind host is loopback.
///
/// Integration-only: the `getifaddrs` walk is the irreducible syscall.
/// The "which host should a remote dial" decision is pure and lives in
/// `ConnectHint.reachableHost`.
enum LocalNetwork {
    /// The primary non-loopback IPv4 address, preferring `en0` (the
    /// built-in Ethernet / Wi-Fi interface on a Mac). Returns nil when
    /// the host is offline or only has loopback.
    static func primaryIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var fallback: String?
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let iface = ptr {
            defer { ptr = iface.pointee.ifa_next }

            let flags = Int32(iface.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0,
                  let addr = iface.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                addr, socklen_t(addr.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            let ip = String(cString: host)

            let name = String(cString: iface.pointee.ifa_name)
            if name == "en0" { return ip }     // the usual primary interface
            if fallback == nil { fallback = ip }
        }
        return fallback
    }
}
