import Foundation

struct ReviewSourceSearchInput: Codable, Sendable {
    var root: String
    var terms: [String]
    var maxMatches: Int?
}

struct ReviewSourceSearchResult: Codable, Sendable {
    var root: String
    var matches: [ReviewSourceMatch]
}

struct ReviewSourceMatch: Codable, Sendable {
    var term: String
    var path: String
    var line: Int
    var preview: String
}

enum ReviewSourceSearcher {
    static func search(_ input: ReviewSourceSearchInput) throws -> ReviewSourceSearchResult {
        let root = URL(fileURLWithPath: input.root).standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw ReviewSourceSearchError.missingRoot(input.root)
        }

        let terms = input.terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 160 }
            .uniqued()
            .prefix(10)
        let maxMatches = max(1, min(input.maxMatches ?? 30, 80))
        var matches: [ReviewSourceMatch] = []

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return ReviewSourceSearchResult(root: root.path, matches: [])
        }

        for case let file as URL in enumerator {
            if shouldSkip(file, root: root) {
                enumerator.skipDescendants()
                continue
            }
            guard isSearchableSource(file),
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  let text = try? String(contentsOf: file, encoding: .utf8) else {
                continue
            }
            let lines = text.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                for term in terms where line.localizedCaseInsensitiveContains(term) {
                    matches.append(ReviewSourceMatch(
                        term: String(term),
                        path: relativePath(file, root: root),
                        line: index + 1,
                        preview: line.trimmingCharacters(in: .whitespaces)
                    ))
                    if matches.count >= maxMatches {
                        return ReviewSourceSearchResult(root: root.path, matches: matches)
                    }
                }
            }
        }

        return ReviewSourceSearchResult(root: root.path, matches: matches)
    }

    private static func shouldSkip(_ url: URL, root: URL) -> Bool {
        let rel = relativePath(url, root: root)
        return rel == "node_modules"
            || rel.hasPrefix("node_modules/")
            || rel == ".git"
            || rel.hasPrefix(".git/")
            || rel == ".expo"
            || rel.hasPrefix(".expo/")
            || rel == ".build"
            || rel.hasPrefix(".build/")
            || rel == "ios/Pods"
            || rel.hasPrefix("ios/Pods/")
            || rel == "android/.gradle"
            || rel.hasPrefix("android/.gradle/")
            || rel == "screen-canvas"
            || rel.hasPrefix("screen-canvas/")
            || rel == "dogfood-output"
            || rel.hasPrefix("dogfood-output/")
    }

    private static func isSearchableSource(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "js", "jsx", "ts", "tsx", "mjs", "cjs", "json":
            return true
        default:
            return false
        }
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if url.path.hasPrefix(rootPath) {
            return String(url.path.dropFirst(rootPath.count))
        }
        return url.lastPathComponent
    }
}

enum ReviewSourceSearchError: Error, CustomStringConvertible {
    case missingRoot(String)

    var description: String {
        switch self {
        case .missingRoot(let path):
            return "source root does not exist: \(path)"
        }
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
