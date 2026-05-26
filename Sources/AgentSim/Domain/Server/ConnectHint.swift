import Foundation

/// The copy-pasteable `agent-sim connect …` invitation that `serve`
/// prints at startup, so an operator on another machine knows exactly
/// how to dial in. Pure rendering + host selection; the LAN-address
/// lookup that feeds `reachableHost` is integration-only.
enum ConnectHint {
    /// Render the remote connect command for the given reachable base
    /// URL, including `--udid` only when a target simulator is known.
    static func line(base: String, udid: String?) -> String {
        var line = "agent-sim connect \(base)"
        if let udid { line += " --udid \(udid)" }
        return line
    }

    /// Pick the host a *remote* device should dial. Neither a loopback
    /// bind (`127.0.0.1`) nor a wildcard bind (`0.0.0.0` / `::`, "all
    /// interfaces") is dialable off-box, so for both prefer the discovered
    /// LAN address; otherwise show the bind host verbatim (the operator
    /// substitutes a reachable address or a tunnel URL).
    static func reachableHost(bind: String, lan: String?) -> String {
        if isLoopback(bind) || isWildcard(bind), let lan { return lan }
        return bind
    }

    static func isLoopback(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower == "127.0.0.1" || lower == "::1" || lower == "localhost"
    }

    /// A wildcard bind names no single interface — it cannot be dialed.
    static func isWildcard(_ host: String) -> Bool {
        let lower = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return lower == "0.0.0.0" || lower == "::"
    }
}
