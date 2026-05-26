import ArgumentParser
import Foundation

/// `agent-sim serve [--port 8421] [--host 127.0.0.1] [--device-set …]
///  [--trusted-host <name> …]`
///
/// Boots the standalone simulator UI. Open `http://<host>:<port>/`
/// in a browser and the simulator picker loads — no SPA dependency,
/// no asc-cli host required.
///
/// `--trusted-host` (repeatable) allowlists a hostname so a loopback
/// bind is reachable over a private mesh (Tailscale / VPN): bind to
/// `127.0.0.1` as usual, then
/// `serve --trusted-host <name>.<tailnet>.ts.net` lets the MagicDNS
/// name through the DNS-rebind guard while same-origin still holds.
struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Start the standalone simulator UI server"
    )

    @Option(name: .long, help: "Port to listen on")
    var port: Int = 8421

    @Option(name: .long, help: "Host / interface to bind to")
    var host: String = "127.0.0.1"

    @Option(name: .long, help: "Custom CoreSimulator device-set path")
    var deviceSet: String?

    @Option(
        name: .long,
        help: "Hostname allowed past the DNS-rebind guard (repeatable; e.g. a Tailscale MagicDNS name)"
    )
    var trustedHost: [String] = []

    @Option(
        name: .long,
        help: "Expose the loopback server over a public tunnel: cloudflare | ngrok"
    )
    var tunnel: String?

    @Flag(
        inversion: .prefixedNo,
        help: "On startup, boot an \"agent-sim\" simulator on the latest runtime when none is running (--no-auto-boot to skip)"
    )
    var autoBoot: Bool = true

    /// Name of the simulator serve auto-provisions on an idle host.
    static let autoBootName = "agent-sim"

    /// Map the `--tunnel` flag to a `Tunnel.Provider`, or `nil` when
    /// the flag is absent. An unrecognised spelling is a usage error,
    /// not a silent no-op — surface it as a `ValidationError` so the
    /// CLI prints the supported providers.
    func resolvedTunnelProvider() throws -> Tunnel.Provider? {
        guard let tunnel else { return nil }
        guard let provider = Tunnel.Provider(rawValue: tunnel) else {
            let supported = Tunnel.Provider.allCases.map(\.rawValue).joined(separator: " | ")
            throw ValidationError("unknown --tunnel provider '\(tunnel)'; supported: \(supported)")
        }
        return provider
    }

    func run() async throws {
        // Resolve the tunnel choice up front so an unknown provider
        // fails as a usage error before we bind anything.
        let provider = try resolvedTunnelProvider()

        // A quick tunnel's public hostname is discovered at runtime, so
        // the guard can't allowlist it at bind time. The running tunnel
        // drops it in here and the server reads the live snapshot.
        let discovered = DiscoveredHosts()

        let simulators = CoreSimulators(deviceSetPath: deviceSet)

        // Turnkey startup: on an idle host bring up a simulator so the
        // picker isn't empty. The decision is pure; the boot/create
        // side effects below are integration glue.
        let suggestedUDID = autoBoot
            ? provisionSimulator(simulators)
            : simulators.all.first(where: { $0.state == .booted })?.udid

        let server = Server(
            simulators: simulators,
            chromes: LiveChromes(
                store: FileSystemChromeStore(),
                rasterizer: CoreGraphicsPDFRasterizer()
            ),
            host: host,
            port: port,
            trustedHosts: Set(trustedHost),
            dynamicTrustedHosts: { discovered.current() }
        )

        // Held for the lifetime of `run()` so the child isn't reaped;
        // the server below never returns under normal operation.
        var runningTunnel: HostTunnel?
        if let provider {
            let hostTunnel = HostTunnel(tunnel: Tunnel(provider: provider, localPort: port))
            try hostTunnel.start(
                onURL: { url in
                    if let discoveredHost = url.host { discovered.insert(discoveredHost) }
                    log("[tunnel] public URL: \(url.absoluteString)")
                    log("[tunnel] remote: \(ConnectHint.line(base: url.absoluteString, udid: suggestedUDID))")
                },
                onExit: { error in
                    if let error {
                        log("[tunnel] exited: \(error)")
                    } else {
                        log("[tunnel] exited cleanly")
                    }
                }
            )
            runningTunnel = hostTunnel
        }
        defer { runningTunnel?.stop() }

        // Show how a device on another machine dials in. Loopback isn't
        // reachable off-box, so prefer this Mac's LAN address; a tunnel
        // (if any) reprints with its public URL once discovered above.
        let reachable = ConnectHint.reachableHost(bind: host, lan: LocalNetwork.primaryIPv4())
        let base = "http://\(reachable):\(port)"
        log("remote: \(ConnectHint.line(base: base, udid: suggestedUDID))")

        try await server.run()
    }

    /// Make sure a simulator is up for the picker to attach to, and
    /// report the UDID a remote `connect` should target.
    /// `SimulatorStartupPlan` decides; this just executes the side
    /// effect and logs. Best-effort — a failed auto-boot is non-fatal,
    /// the operator can still pick an existing device in the web UI.
    @discardableResult
    private func provisionSimulator(_ simulators: CoreSimulators) -> String? {
        switch SimulatorStartupPlan.decide(all: simulators.all, desiredName: Self.autoBootName) {
        case .useRunning:
            log("[serve] simulator already running — using it")
            return simulators.all.first(where: { $0.state == .booted || $0.state == .booting })?.udid
        case .bootExisting(let udid):
            log("[serve] booting existing \"\(Self.autoBootName)\" (\(udid))…")
            do { try simulators.find(udid: udid)?.boot() }
            catch { log("[serve] auto-boot failed: \(error)") }
            return udid
        case .createAndBoot(let name):
            log("[serve] no booted simulator — creating \"\(name)\" on the latest runtime…")
            do {
                let sim = try simulators.createSimulator(named: name)
                try sim.boot()
                log("[serve] booted \(sim.name) (\(sim.udid))")
                return sim.udid
            } catch {
                log("[serve] auto-boot failed: \(error)")
                return nil
            }
        }
    }
}
