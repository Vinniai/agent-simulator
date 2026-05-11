import Foundation

enum ReviewFingerprint {
    static func axTreeFingerprint(_ axJSON: String) -> String {
        let normalized = normalizeAXJSON(axJSON) ?? axJSON
        return fnv1a64(normalized)
    }

    private static func normalizeAXJSON(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        let normalized = normalize(object)
        guard let out = try? JSONSerialization.data(
            withJSONObject: normalized,
            options: [.sortedKeys]
        ) else {
            return nil
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func normalize(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for key in ["role", "label", "identifier", "title", "enabled", "hidden", "frame"] {
                if let v = dict[key] {
                    out[key] = key == "frame" ? normalizeFrame(v) : v
                }
            }
            if let children = dict["children"] as? [Any] {
                out["children"] = children.map(normalize)
            }
            return out
        }
        if let array = value as? [Any] {
            return array.map(normalize)
        }
        return value
    }

    private static func normalizeFrame(_ value: Any) -> Any {
        guard let dict = value as? [String: Any] else { return value }
        var out: [String: Int] = [:]
        for key in ["x", "y", "width", "height"] {
            if let n = dict[key] as? NSNumber {
                out[key] = Int(n.doubleValue.rounded())
            }
        }
        return out
    }

    private static func fnv1a64(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

