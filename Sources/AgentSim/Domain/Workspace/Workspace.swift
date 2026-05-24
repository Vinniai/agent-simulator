import Foundation

/// The on-disk project that the simulator's frontmost app was built
/// from. Knowing the workspace lets us walk the screen file the
/// element came from for source-line triangulation.
///
/// Phase A pins the value type + framework detection. Subsequent
/// phases hang JSX scanning (Phase B) and React-DevTools fiber
/// lookup (Phase C) off the same `Workspace` value.
struct Workspace: Equatable {
    let root: URL
    let framework: Framework

    enum Framework: String, Equatable {
        case expoRouter   // `app/` filesystem routes via expo-router
        case unknown      // plain RN, native iOS, anything else
    }

    /// Pure framework detection from a `package.json` file's raw
    /// contents. Returns `.expoRouter` when `expo-router` appears
    /// in either `dependencies` or `devDependencies`. Malformed
    /// JSON or missing dependency stanzas fall back to `.unknown`
    /// — callers can still use the workspace, just without the
    /// expo-router-specific path mapping.
    static func detectFramework(packageJSON: String) -> Framework {
        guard let data = packageJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unknown }
        let deps = (obj["dependencies"] as? [String: Any]) ?? [:]
        let devDeps = (obj["devDependencies"] as? [String: Any]) ?? [:]
        if deps["expo-router"] != nil || devDeps["expo-router"] != nil {
            return .expoRouter
        }
        return .unknown
    }
}
