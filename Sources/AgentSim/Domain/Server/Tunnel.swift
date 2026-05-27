import Foundation

/// A public ingress that exposes a loopback `agent-simulator serve` to the
/// internet without inbound port-forwarding — the Mac-mini-at-home →
/// Claude-on-the-web case. The mini dials *out* to a tunnel provider,
/// which hands back a public HTTPS hostname proxying to `localhost`.
///
/// `Tunnel` is a pure description: which external CLI to run, the argv
/// to run it with, and how to read the advertised public URL back out
/// of the child's output. Launching the process and pumping its bytes
/// is `HostTunnel`'s job (over the `Subprocess` collaborator); this
/// value type stays testable without spawning anything.
///
/// Only *quick* / ephemeral tunnels are modelled: the public hostname
/// is assigned by the provider at runtime and discovered by parsing
/// the child's banner. Operators who run a pre-configured named tunnel
/// (stable hostname + DNS) keep doing that out-of-band and pass the
/// hostname via `serve --trusted-host`.
struct Tunnel: Equatable, Sendable {
    /// The tunnel CLIs agent-simulator knows how to launch. The raw value is
    /// also the `serve --tunnel <value>` flag spelling.
    enum Provider: String, CaseIterable, Sendable {
        case cloudflare
        case ngrok
    }

    let provider: Provider
    /// The loopback port `agent-simulator serve` is bound to — what the
    /// tunnel proxies public traffic into.
    let localPort: Int

    /// The executable name, resolved against `PATH` at launch time.
    var executable: String {
        switch provider {
        case .cloudflare: return "cloudflared"
        case .ngrok:      return "ngrok"
        }
    }

    /// Argv for an ephemeral tunnel pointed at the loopback bind.
    ///
    /// ngrok defaults to a full-screen TUI; `--log=stdout
    /// --log-format=logfmt` forces the machine-parseable line stream
    /// `publicURL(in:)` reads. cloudflared already logs its quick-tunnel
    /// banner to stderr, which `HostTunnel` pools with stdout.
    var arguments: [String] {
        switch provider {
        case .cloudflare:
            return ["tunnel", "--url", "http://127.0.0.1:\(localPort)"]
        case .ngrok:
            return ["http", "\(localPort)", "--log=stdout", "--log-format=logfmt"]
        }
    }

    /// Scan one line of the child's output for the public ingress URL
    /// it advertises, returning the first `https://` token whose host
    /// belongs to this provider's domain. Lines that carry no such URL
    /// (timestamps, box-drawing borders, unrelated log entries) yield
    /// `nil`.
    ///
    /// The URL turns up in different shapes per provider — cloudflared
    /// centres it inside a box-drawing banner
    /// (`|  https://x.trycloudflare.com  |`), ngrok emits it as a
    /// logfmt field (`url=https://x.ngrok-free.app`) — so we slice on
    /// whitespace and strip surrounding punctuation rather than assume
    /// a fixed column.
    func publicURL(in line: String) -> URL? {
        var search = Substring(line)
        while let marker = search.range(of: "https://") {
            let token = search[marker.lowerBound...].prefix { !$0.isWhitespace }
            let trimmed = token.trimmingCharacters(
                in: CharacterSet(charactersIn: "|\"'<>(),")
            )
            if let url = URL(string: trimmed),
               let host = url.host,
               hostBelongsToProvider(host) {
                return url
            }
            search = search[marker.upperBound...]
        }
        return nil
    }

    private func hostBelongsToProvider(_ host: String) -> Bool {
        let lower = host.lowercased()
        switch provider {
        case .cloudflare: return lower.hasSuffix(".trycloudflare.com")
        case .ngrok:      return lower.contains("ngrok")
        }
    }
}

/// Failure vocabulary for running a `Tunnel`. `HostTunnel` throws
/// `alreadyStarted` / `launchFailed` synchronously from `start`, and
/// reports `nonZeroExit` through its `onExit` callback when the child
/// dies on its own.
enum TunnelError: Error, Equatable {
    case alreadyStarted
    case launchFailed(reason: String)
    case nonZeroExit(code: Int32)
}
