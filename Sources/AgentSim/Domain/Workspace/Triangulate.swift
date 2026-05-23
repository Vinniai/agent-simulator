import Foundation

/// One-shot use case: hit-test an AX point AND discover the workspace
/// that owns the running app. Candidates (source-line pointers) ride
/// the same result envelope but stay empty in Phase A — they hang
/// off the JSX scanner (Phase B) and the React DevTools fiber lookup
/// (Phase C). Keeping the result shape stable now lets the client
/// land safely before those backends arrive.
struct TriangulationResult: Equatable {
    let node: AXNode?
    let workspace: Workspace?
    let candidates: [SourceCandidate]
}

/// Where an AX node was produced in the workspace's source tree. A
/// single hit can resolve to multiple candidates ranked by
/// confidence; Phase A always returns `[]`.
struct SourceCandidate: Equatable {
    let file: URL
    let line: Int
    let column: Int
    let confidence: Double
    let component: String?
}

enum Triangulate {
    static func run(
        point: Point,
        accessibility: any Accessibility,
        metro: any Metro,
        listFiles: (URL) -> [URL] = JSXScanner.defaultListFiles,
        readFile: (URL) -> String? = { try? String(contentsOf: $0) }
    ) async throws -> TriangulationResult {
        // Pull the full tree so we can derive both the hit *and* the
        // context bag (siblings + nearest labeled ancestors) the JSX
        // scanner uses to disambiguate candidates. Hit-testing happens
        // in-domain (`AXNode.hitTest`) — no extra XPC round-trip.
        let tree = try accessibility.describeAll()
        let node = tree?.hitTest(point)
        let context = tree?.contextBag(at: point) ?? []
        let workspace = await Workspace.discover(metro: metro, readFile: readFile)
        let candidates: [SourceCandidate]
        if let node, let workspace {
            candidates = JSXScanner.scan(
                node: node, workspace: workspace, context: context,
                listFiles: listFiles, readFile: readFile
            )
        } else {
            candidates = []
        }
        return TriangulationResult(node: node, workspace: workspace, candidates: candidates)
    }
}

/// Wire shape for `POST /triangulate`. UDID picks the simulator (its
/// AX collaborator), `x` / `y` are device-point coordinates in the
/// same units as gestures / chrome / describe_ui.
struct TriangulateInput: Decodable, Equatable {
    let udid: String
    let x: Double
    let y: Double
}

extension TriangulationResult {
    /// JSON envelope returned by `/triangulate`. Phase A always emits
    /// `candidates: []`; the field is reserved so Phase B (static JSX
    /// scan) and Phase C (React DevTools fiber) can populate it
    /// without a wire-format change.
    var json: String {
        let nodeFrag = node?.json ?? "null"
        let wsFrag: String
        if let ws = workspace {
            let dict: [String: Any] = [
                "root": ws.root.path,
                "framework": ws.framework.rawValue,
            ]
            let data = try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            wsFrag = String(decoding: data, as: UTF8.self)
        } else {
            wsFrag = "null"
        }
        let candArr = candidates.map { c -> [String: Any] in
            var d: [String: Any] = [
                "file": c.file.path,
                "line": c.line,
                "column": c.column,
                "confidence": c.confidence,
            ]
            if let comp = c.component { d["component"] = comp }
            return d
        }
        let candData = try! JSONSerialization.data(
            withJSONObject: candArr, options: [.sortedKeys]
        )
        let candFrag = String(decoding: candData, as: UTF8.self)
        return #"{"ok":true,"node":\#(nodeFrag),"workspace":\#(wsFrag),"candidates":\#(candFrag)}"#
    }
}
