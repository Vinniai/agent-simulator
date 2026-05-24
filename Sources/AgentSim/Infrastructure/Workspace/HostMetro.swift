import Foundation

/// Concrete `Metro` that discovers a locally-running Metro dev server
/// by probing `http://localhost:<port>/status` (the "packager is alive"
/// endpoint) and resolving the listening process's cwd via `lsof`.
///
/// Untestable by design — the four-line dance (status probe / lsof /
/// pid / cwd) IS the integration. The pure orchestration lives in
/// `Workspace.discover(metro:readFile:)` and is covered there.
final class HostMetro: Metro {
    private let port: Int
    private let session: URLSession

    init(port: Int = 8081, session: URLSession = .shared) {
        self.port = port
        self.session = session
    }

    func projectRoot() async -> URL? {
        guard await isMetroAlive() else { return nil }
        return metroProcessCWD()
    }

    private func isMetroAlive() async -> Bool {
        guard let url = URL(string: "http://localhost:\(port)/status") else { return false }
        var req = URLRequest(url: url, timeoutInterval: 0.8)
        req.httpMethod = "GET"
        do {
            let (data, response) = try await session.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            return String(decoding: data, as: UTF8.self).contains("packager-status:running")
        } catch {
            return false
        }
    }

    private func metroProcessCWD() -> URL? {
        // 1. find the pid listening on the Metro port
        let pidOut = run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fp"])
        guard let pidLine = pidOut?.split(separator: "\n").first(where: { $0.hasPrefix("p") }),
              let pid = Int(pidLine.dropFirst())
        else { return nil }
        // 2. ask lsof for its cwd. The `-a` flag ANDs `-p` with `-d cwd`
        //    — without it macOS lsof ORs the two selectors and prints
        //    every process's cwd in the system, the first of which is
        //    pid 1 ("/").
        let cwdOut = run("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"])
        guard let nameLine = cwdOut?.split(separator: "\n").first(where: { $0.hasPrefix("n") })
        else { return nil }
        let path = String(nameLine.dropFirst())
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func run(_ path: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}
