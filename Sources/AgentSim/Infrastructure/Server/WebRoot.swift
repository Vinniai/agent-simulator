import Foundation

/// Locator for the static web assets (`simulators.html` and friends)
/// that `agent-sim serve` serves. Files live at
/// `Sources/AgentSim/Resources/Web/` and are bundled into the
/// executable as SPM resources for release.
///
/// Lookup order:
///   1. `$AGENTSIM_WEB_DIR` — explicit override, ideal for live
///      iteration on the HTML without rebuilding. `$BAGUETTE_WEB_DIR`
///      is honoured as a legacy fallback.
///   2. Source-tree path (dev) — when the running executable lives
///      inside the package's `.build/`, walk up to the package root
///      and read directly from `Sources/AgentSim/Resources/Web/`.
///      Edits show on the next browser refresh; no rebuild.
///   3. Sidecar `agent-sim_AgentSim.bundle` next to the executable,
///      with `agent-sim_Baguette.bundle` and `Baguette_Baguette.bundle`
///      kept as legacy fallbacks. These are SPM-generated resource
///      bundles. We resolve manually via `dladdr` instead of
///      `Bundle.module` because the latter `fatalError`s when the
///      bundle is missing (e.g. an install that didn't ship the
///      bundle next to the binary).
///
/// `data(named:)` is used by the route handlers; the resolution logic
/// runs once per call which is fine — the OS caches the file pages.
struct WebRoot {
    static let sidecarBundleNames = [
        "agent-sim_AgentSim.bundle",
        "agent-sim_Baguette.bundle",
        "Baguette_Baguette.bundle",
    ]

    /// Read a file as UTF-8 text, with the same lookup as `data`.
    static func string(named filename: String) -> String? {
        data(named: filename).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Read a file by name (e.g. `"simulators.html"`). Returns nil
    /// when the asset is missing across every lookup path.
    static func data(named filename: String) -> Data? {
        guard let filename = safeRelativeAssetPath(filename) else { return nil }
        let env = ProcessInfo.processInfo.environment
        if let path = env["AGENTSIM_WEB_DIR"] ?? env["BAGUETTE_WEB_DIR"],
           let data = read(URL(fileURLWithPath: path).appendingPathComponent(filename)) {
            return data
        }
        if let dev = sourceTreeRoot()?.appendingPathComponent(filename),
           let data = read(dev) {
            return data
        }
        if let bundled = sidecarWebURL(for: filename),
           let data = read(bundled) {
            return data
        }
        return nil
    }

    // MARK: - private

    /// Keep static asset lookups inside the web root even when a route
    /// passes a percent-decoded path segment such as `..%2FPackage.swift`.
    private static func safeRelativeAssetPath(_ filename: String) -> String? {
        guard !filename.isEmpty, !filename.hasPrefix("/") else { return nil }
        let scalars = filename.unicodeScalars
        guard scalars.allSatisfy({ scalar in
            scalar == "/" || scalar == "." || scalar == "-" || scalar == "_"
                || ("a"..."z").contains(scalar)
                || ("A"..."Z").contains(scalar)
                || ("0"..."9").contains(scalar)
        }) else { return nil }

        let parts = filename.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        for part in parts {
            guard !part.isEmpty, part != ".", part != ".." else { return nil }
        }
        return parts.joined(separator: "/")
    }

    private static func read(_ url: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Walk up from the executable to find a sibling
    /// `Sources/AgentSim/Resources/Web/` — only matches when running
    /// out of `.build/`. Falls back to the legacy `Sources/Baguette/…`
    /// path so a partially-renamed checkout still resolves assets.
    /// Returns nil otherwise (release install).
    private static func sourceTreeRoot() -> URL? {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0,
              let cstr = info.dli_fname else { return nil }
        var url = URL(fileURLWithPath: String(cString: cstr)).deletingLastPathComponent()
        let candidates = ["Sources/AgentSim/Resources/Web", "Sources/Baguette/Resources/Web"]
        for _ in 0..<6 {
            for sub in candidates {
                let candidate = url.appendingPathComponent(sub)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
                   isDir.boolValue {
                    return candidate
                }
            }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    /// Resolve a file inside the SPM-generated sidecar resource bundle
    /// expected to sit next to the running executable. Returns nil when
    /// no supported bundle is there (e.g. a binary-only install that forgot
    /// to ship the bundle). Crucially, this avoids `Bundle.module`,
    /// which `fatalError`s on miss.
    ///
    /// `filename` may include a subdirectory segment (e.g.
    /// `farm/farm.html`); the path is split into a subdirectory and
    /// leaf so the bundle's `subdirectory:` argument matches what
    /// `.copy("Resources/Web")` produces in the resource bundle.
    private static func sidecarWebURL(for filename: String) -> URL? {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0,
              let cstr = info.dli_fname else { return nil }
        let exeDir = URL(fileURLWithPath: String(cString: cstr)).deletingLastPathComponent()
        let bundle = sidecarBundleNames.lazy
            .map { exeDir.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
            .flatMap { Bundle(url: $0) }
        guard let bundle else { return nil }
        let parts = filename.split(separator: "/", omittingEmptySubsequences: true)
        let subdir: String = parts.count > 1
            ? "Web/" + parts.dropLast().joined(separator: "/")
            : "Web"
        let leaf = String(parts.last ?? Substring(filename))
        return bundle.url(
            forResource: (leaf as NSString).deletingPathExtension,
            withExtension: (leaf as NSString).pathExtension,
            subdirectory: subdir
        )
    }
}
