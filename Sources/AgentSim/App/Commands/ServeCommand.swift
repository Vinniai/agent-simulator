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

    func run() async throws {
        let server = Server(
            simulators: CoreSimulators(deviceSetPath: deviceSet),
            chromes: LiveChromes(
                store: FileSystemChromeStore(),
                rasterizer: CoreGraphicsPDFRasterizer()
            ),
            host: host,
            port: port,
            trustedHosts: Set(trustedHost)
        )
        try await server.run()
    }
}
