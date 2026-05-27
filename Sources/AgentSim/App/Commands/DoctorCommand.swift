import ArgumentParser
import Foundation

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Report CLI / server / simulator health and surface version drift"
    )

    @Option(name: .long, help: "URL of the running agent-simulator server")
    var base: String = "http://127.0.0.1:8421"

    @Option(name: .long, help: "Probe timeout in seconds")
    var timeout: Double = 2.0

    @Flag(name: .long, help: "Emit a JSON report instead of plain text")
    var json: Bool = false

    func run() async throws {
        let report = await gatherReport(
            cliVersion: agentSimVersion,
            isDebugBuild: Self.isDebugBuild,
            base: base,
            timeout: timeout,
            simulators: CoreSimulators(deviceSetPath: nil)
        )

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            print(String(decoding: data, as: UTF8.self))
        } else {
            print(report.textReport())
        }
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}

func gatherReport(
    cliVersion: String,
    isDebugBuild: Bool,
    base: String,
    timeout: Double,
    simulators: any Simulators
) async -> DoctorReport {
    let booted = simulators.running.count
    let (reachable, serverVersion) = await probeServer(base: base, timeout: timeout)
    return DoctorReport(
        cliVersion: cliVersion,
        isDebugBuild: isDebugBuild,
        bootedSimulatorCount: booted,
        serverBase: base,
        serverReachable: reachable,
        serverVersion: serverVersion
    )
}

private func probeServer(base: String, timeout: Double) async -> (reachable: Bool, version: String?) {
    if let version = await fetchVersion(base: base, timeout: timeout) {
        return (true, version)
    }
    // The /version endpoint landed in this commit; older running
    // servers respond 404 here even though they're up. Fall back to
    // a known-old endpoint so we can still mark the server reachable
    // and surface the drift in the report.
    if await isReachable(base: base, timeout: timeout) {
        return (true, nil)
    }
    return (false, nil)
}

private func fetchVersion(base: String, timeout: Double) async -> String? {
    guard let url = URL(string: "\(base)/version") else { return nil }
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = "GET"
    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = json["version"] as? String {
            return version
        }
        return nil
    } catch {
        return nil
    }
}

private func isReachable(base: String, timeout: Double) async -> Bool {
    guard let url = URL(string: "\(base)/simulators.json") else { return false }
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = "GET"
    do {
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }
        return (200..<500).contains(http.statusCode)
    } catch {
        return false
    }
}
