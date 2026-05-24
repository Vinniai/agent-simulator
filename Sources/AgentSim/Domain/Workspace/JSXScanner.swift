import Foundation

/// Static JSX scanner — Phase B of source triangulation. Given an AX
/// hit and a discovered `Workspace`, grep the workspace's source tree
/// for the node's `label` and rank candidates by where it appears:
///
///   - `accessibilityLabel="<label>"`  → 0.9 (intentional anchor)
///   - JSX text content `>…<label>…<` → 0.8 (visual match)
///
/// The component name is inferred from the nearest preceding
/// capitalized JSX tag on the same line; if none, it stays `nil`.
///
/// Pure by construction — `listFiles` and `readFile` are injected so
/// tests don't touch disk. `Triangulate.run` wires it to disk in
/// production via `JSXScanner.walk` and `String(contentsOf:)`.
///
/// Phase B only runs for `.expoRouter` workspaces today. Other
/// frameworks fall through to `[]` so callers don't ship false-positive
/// candidates from React-Native-Cli or unknown trees until those
/// dialects get their own scanner.
enum JSXScanner {

    /// Per-match bonus and cap for context-label hits within
    /// `contextWindow` lines of a candidate. Keeps the existing
    /// 0.9 / 0.8 tiers as base confidences and pushes a candidate
    /// up by how much surrounding context it shares with the AX
    /// neighbours of the tapped node — a file that mentions
    /// "Notifications" near a `<Text>Name</Text>` outranks one
    /// that has the same `Name` in isolation.
    static let contextBonusPerMatch = 0.05
    static let contextBonusCap = 0.2
    static let contextWindow = 20

    static func scan(
        node: AXNode,
        workspace: Workspace,
        context: [String] = [],
        listFiles: (URL) -> [URL],
        readFile: (URL) -> String?
    ) -> [SourceCandidate] {
        guard workspace.framework == .expoRouter,
              let label = node.label, !label.isEmpty
        else { return [] }

        var hits: [SourceCandidate] = []
        for url in listFiles(workspace.root) where isJSXLike(url) {
            guard let source = readFile(url) else { continue }
            let raw = scanFile(url: url, source: source, label: label)
            hits.append(contentsOf: raw.map { applyContextBonus($0, source: source, context: context) })
        }
        return hits.sorted { $0.confidence > $1.confidence }
    }

    /// Boost a candidate by counting how many unique `context`
    /// labels appear within `±contextWindow` lines of its hit
    /// line. Bonus is `contextBonusPerMatch` per unique label,
    /// capped at `contextBonusCap`; final confidence is clamped
    /// to `[0, 1]`. Context labels equal to the hit's own
    /// surface text are pre-filtered by `AXNode.contextBag`, so
    /// the same label can't double-count.
    private static func applyContextBonus(
        _ candidate: SourceCandidate, source: String, context: [String]
    ) -> SourceCandidate {
        guard !context.isEmpty else { return candidate }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let hitIdx = candidate.line - 1
        let lo = max(0, hitIdx - contextWindow)
        let hi = min(lines.count - 1, hitIdx + contextWindow)
        guard lo <= hi else { return candidate }
        let window = lines[lo...hi].joined(separator: "\n")
        var matched: Set<String> = []
        for label in context where !label.isEmpty {
            if window.range(of: label) != nil { matched.insert(label) }
        }
        let bonus = min(Double(matched.count) * contextBonusPerMatch, contextBonusCap)
        let final = min(1.0, candidate.confidence + bonus)
        return SourceCandidate(
            file: candidate.file, line: candidate.line, column: candidate.column,
            confidence: final, component: candidate.component
        )
    }

    // MARK: - file walk

    static func defaultListFiles(_ root: URL) -> [URL] {
        // Skip-list rather than allow-list: real Expo projects keep
        // JSX outside `app/components/screens/` (e.g. `features/`,
        // `src/`, `lib/`). Walk the whole tree once and prune the
        // build-output / vendor dirs that explode the file count.
        let skip: Set<String> = [
            "node_modules", ".git", ".expo", "ios", "android",
            "build", "dist", ".next", "coverage",
        ]
        var out: [URL] = []
        guard let it = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        while let next = it.nextObject() as? URL {
            if skip.contains(next.lastPathComponent) {
                it.skipDescendants()
                continue
            }
            if isJSXLike(next) { out.append(next) }
        }
        return out
    }

    private static func isJSXLike(_ url: URL) -> Bool {
        switch url.pathExtension {
        case "tsx", "jsx", "ts", "js": return true
        default: return false
        }
    }

    // MARK: - line scan

    private static func scanFile(
        url: URL, source: String, label: String
    ) -> [SourceCandidate] {
        var out: [SourceCandidate] = []
        let rawLines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let lines = rawLines.map(String.init)
        for (i, line) in lines.enumerated() {
            // accessibilityLabel="<label>" — anchor wins.
            let axNeedle = #"accessibilityLabel=""# + label + #"""#
            if let r = line.range(of: axNeedle) {
                out.append(SourceCandidate(
                    file: url, line: i + 1,
                    column: line.distance(from: line.startIndex, to: r.lowerBound) + 1,
                    confidence: 0.9,
                    component: nearestComponentBefore(lineIndex: i, in: lines)
                ))
                continue
            }

            // Inline JSX text node — `>…<label>…<` on the same line.
            let textNeedle = ">" + label + "<"
            if let r = line.range(of: textNeedle) {
                let textStart = line.index(after: r.lowerBound)
                out.append(SourceCandidate(
                    file: url, line: i + 1,
                    column: line.distance(from: line.startIndex, to: textStart) + 1,
                    confidence: 0.8,
                    component: nearestComponentBefore(lineIndex: i, in: lines)
                ))
                continue
            }

            // Multi-line JSX text — label sits alone (with whitespace
            // padding) on its own line between a `>` open and a `<`
            // close. Cheap and false-positive-resistant: the trimmed
            // line must equal the label exactly.
            if line.trimmingCharacters(in: .whitespaces) == label {
                let col = line.firstIndex(where: { !$0.isWhitespace })
                    .map { line.distance(from: line.startIndex, to: $0) + 1 } ?? 1
                out.append(SourceCandidate(
                    file: url, line: i + 1,
                    column: col,
                    confidence: 0.8,
                    component: nearestComponentBefore(lineIndex: i, in: lines)
                ))
            }
        }
        return out
    }

    /// Component name for a hit on `lineIndex`. Looks first on the
    /// hit line itself (inline JSX), then scans upward for the most
    /// recent unclosed `<Capitalized` opening tag.
    private static func nearestComponentBefore(
        lineIndex: Int, in lines: [String]
    ) -> String? {
        if let inline = nearestComponent(in: lines[lineIndex]) {
            return inline
        }
        var j = lineIndex - 1
        while j >= 0 {
            if let comp = nearestComponent(in: lines[j]) {
                return comp
            }
            j -= 1
        }
        return nil
    }

    /// Last capitalized JSX tag opened on the line — `<Pressable …`
    /// → `Pressable`. Returns nil when no such tag appears.
    private static func nearestComponent(in line: String) -> String? {
        var last: String?
        var i = line.startIndex
        while i < line.endIndex {
            if line[i] == "<", let start = line.index(i, offsetBy: 1, limitedBy: line.endIndex),
               start < line.endIndex, line[start].isUppercase
            {
                var j = start
                while j < line.endIndex,
                      line[j].isLetter || line[j].isNumber || line[j] == "_"
                { j = line.index(after: j) }
                last = String(line[start..<j])
                i = j
            } else {
                i = line.index(after: i)
            }
        }
        return last
    }
}
