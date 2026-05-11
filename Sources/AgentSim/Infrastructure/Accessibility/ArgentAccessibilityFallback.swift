import Foundation

enum ArgentAccessibilityFallback {
    static func describeAll(udid: String) throws -> AXNode? {
        guard let argent = resolveArgentExecutable() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argent)
        process.arguments = [
            "run", "describe",
            "--udid", udid,
            "--json"
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            logErr("[ax] argent describe timed out for udid=\(udid)")
            return nil
        }
        guard process.terminationStatus == 0 else {
            let message = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !message.isEmpty {
                logErr("[ax] argent describe failed: \(message)")
            }
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return try parseDescribeOutput(data)
    }

    static func parseDescribeOutput(_ data: Data) throws -> AXNode? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tree = object["tree"] as? [String: Any] else {
            return nil
        }
        return parseNode(tree)
    }

    private static func parseNode(_ dict: [String: Any]) -> AXNode? {
        guard let role = dict["role"] as? String,
              let frame = parseFrame(dict["frame"]) else {
            return nil
        }
        let children = (dict["children"] as? [[String: Any]] ?? [])
            .compactMap(parseNode)
        return AXNode(
            role: role,
            subrole: dict["subrole"] as? String,
            label: dict["label"] as? String,
            value: stringOrNumber(dict["value"]),
            identifier: dict["identifier"] as? String,
            title: dict["title"] as? String,
            help: dict["help"] as? String,
            frame: frame,
            enabled: (dict["enabled"] as? Bool) ?? true,
            focused: (dict["focused"] as? Bool) ?? false,
            hidden: (dict["hidden"] as? Bool) ?? false,
            children: children
        )
    }

    private static func parseFrame(_ raw: Any?) -> Rect? {
        guard let frame = raw as? [String: Any],
              let x = double(frame["x"]),
              let y = double(frame["y"]),
              let width = double(frame["width"]),
              let height = double(frame["height"]) else {
            return nil
        }
        return Rect(
            origin: Point(x: x, y: y),
            size: Size(width: width, height: height)
        )
    }

    private static func double(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func stringOrNumber(_ raw: Any?) -> String? {
        if let value = raw as? String { return value }
        if let value = raw as? NSNumber { return value.stringValue }
        return nil
    }

    private static func resolveArgentExecutable() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["BAGUETTE_ARGENT_BIN"],
            "/opt/homebrew/bin/argent",
            "/usr/local/bin/argent",
            "/usr/bin/argent"
        ].compactMap { $0 }
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }
}
