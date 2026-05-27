import Foundation

final class FileReviewStore: ReviewStore, @unchecked Sendable {
    let root: URL
    private let fm: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    init(root: URL = FileReviewStore.defaultRoot()) {
        self.root = root
        self.fm = FileManager.default
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    static func defaultRoot() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let override = ProcessInfo.processInfo.environment["AGENT_SIM_REVIEW_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return home.appendingPathComponent(".agent-simulator/reviews", isDirectory: true)
    }

    func createSession(name: String) throws -> ReviewSession {
        lock.lock(); defer { lock.unlock() }
        let id = Self.makeID(prefix: "review")
        let session = ReviewSession(
            id: id,
            name: name.isEmpty ? "Untitled review" : name,
            createdAt: Date(),
            devices: [],
            snapshots: [],
            edges: [],
            comments: [],
            bundles: []
        )
        try saveSessionUnlocked(session)
        return session
    }

    func loadSession(id: String) throws -> ReviewSession {
        lock.lock(); defer { lock.unlock() }
        let url = manifestURL(sessionId: id)
        guard fm.fileExists(atPath: url.path) else {
            throw ReviewStoreError.notFound(id)
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode(ReviewSession.self, from: data)
    }

    func saveSession(_ session: ReviewSession) throws {
        lock.lock(); defer { lock.unlock() }
        try saveSessionUnlocked(session)
    }

    func listSessions() throws -> [ReviewSession] {
        lock.lock(); defer { lock.unlock() }
        guard fm.fileExists(atPath: root.path) else { return [] }
        let urls = try fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        )
        return urls.compactMap { url in
            let manifest = url.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifest) else { return nil }
            return try? decoder.decode(ReviewSession.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func writeArtifact(sessionId: String, relativePath: String, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        let url = try artifactURL(sessionId: sessionId, relativePath: relativePath)
        try fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
    }

    func readArtifact(sessionId: String, relativePath: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let url = try artifactURL(sessionId: sessionId, relativePath: relativePath)
        guard fm.fileExists(atPath: url.path) else {
            throw ReviewStoreError.notFound(relativePath)
        }
        return try Data(contentsOf: url)
    }

    private func saveSessionUnlocked(_ session: ReviewSession) throws {
        let dir = sessionURL(session.id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try encoder.encode(session)
        try data.write(to: manifestURL(sessionId: session.id), options: [.atomic])
    }

    private func sessionURL(_ id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    private func manifestURL(sessionId: String) -> URL {
        sessionURL(sessionId).appendingPathComponent("manifest.json")
    }

    private func artifactURL(sessionId: String, relativePath: String) throws -> URL {
        guard !relativePath.contains(".."),
              !relativePath.hasPrefix("/"),
              !relativePath.isEmpty else {
            throw ReviewStoreError.invalidPath(relativePath)
        }
        return sessionURL(sessionId).appendingPathComponent(relativePath)
    }

    static func makeID(prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.lowercased())"
    }
}
