import Foundation

protocol ReviewStore: Sendable {
    var root: URL { get }

    func createSession(name: String) throws -> ReviewSession
    func loadSession(id: String) throws -> ReviewSession
    func saveSession(_ session: ReviewSession) throws
    func listSessions() throws -> [ReviewSession]
    func writeArtifact(sessionId: String, relativePath: String, data: Data) throws
    func readArtifact(sessionId: String, relativePath: String) throws -> Data
}

enum ReviewStoreError: Error, Equatable {
    case notFound(String)
    case invalidPath(String)
}

