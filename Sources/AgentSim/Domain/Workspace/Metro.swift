import Foundation
import Mockable

/// The local Metro dev server. Only ever has one job in our world:
/// tell us where its project root lives so we can pair an AX hit
/// with the source tree the running app was built from.
///
/// Returns `nil` when no Metro is reachable — the triangulation
/// caller falls back gracefully ("no source available") rather
/// than failing the AX request.
@Mockable
protocol Metro: Sendable {
    func projectRoot() async -> URL?
}

extension Workspace {
    /// Composes a `Metro` discovery with `package.json` detection.
    /// `readFile` is injected so tests don't touch disk; production
    /// callers use the default which reads via `FileManager`.
    static func discover(
        metro: any Metro,
        readFile: (URL) -> String? = { try? String(contentsOf: $0) }
    ) async -> Workspace? {
        guard let root = await metro.projectRoot() else { return nil }
        let pkg = readFile(root.appendingPathComponent("package.json")) ?? ""
        return Workspace(root: root, framework: detectFramework(packageJSON: pkg))
    }
}
