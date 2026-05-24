import Foundation

struct DoctorReport: Codable, Equatable, Sendable {
    let cliVersion: String
    let isDebugBuild: Bool
    let bootedSimulatorCount: Int?
    let serverBase: String
    let serverReachable: Bool
    let serverVersion: String?

    var versionMatches: Bool? {
        guard let serverVersion else { return nil }
        return serverVersion == cliVersion
    }

    var status: String {
        if !serverReachable { return "offline" }
        if serverVersion == nil { return "stale" }
        if versionMatches == false { return "drift" }
        return "healthy"
    }

    func textReport() -> String {
        var lines: [String] = ["agent-sim doctor"]
        lines.append("  cli version       \(cliVersion)")
        lines.append("  build mode        \(isDebugBuild ? "debug" : "release")")
        lines.append("  booted sims       \(bootedSimulatorCount.map(String.init(describing:)) ?? "unknown")")
        lines.append("  server            \(serverBase)")
        lines.append("  server reachable  \(serverReachable ? "yes" : "no")")
        lines.append("  server version    \(serverVersion ?? "-")")
        lines.append("  versions match    \(versionMatches.map { $0 ? "yes" : "no" } ?? "-")")
        lines.append("  status            \(status)")
        return lines.joined(separator: "\n")
    }
}
