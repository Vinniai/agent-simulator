import Foundation

struct ReviewTask: Codable, Equatable, Sendable {
    let id: String
    let sessionId: String
    var bundleId: String?
    var title: String
    var instructions: String
    var status: String
    var priority: String
    var assignee: String?
    var contextPath: String?
    var bundleJSONPath: String?
    var bundleMarkdownPath: String?
    var resultSummary: String?
    var verificationSnapshotId: String?
    let createdAt: Date
    var updatedAt: Date
    var claimedAt: Date?
    var completedAt: Date?
    var elements: [ReviewTaskElement]
    var events: [ReviewTaskEvent]
}

struct ReviewTaskElement: Codable, Equatable, Sendable {
    let id: String
    let taskId: String
    let snapshotId: String
    let axNodePath: String
    let role: String?
    let label: String?
    let frame: Rect?
    let commentText: String?
}

struct ReviewTaskEvent: Codable, Equatable, Sendable {
    let id: String
    let taskId: String
    let type: String
    let actor: String?
    let message: String
    let metadataJSON: String?
    let createdAt: Date
}

struct ReviewTaskVerification: Codable, Equatable, Sendable {
    let id: String
    let taskId: String
    let beforeSnapshotIds: [String]
    let afterSnapshotId: String?
    let status: String
    let notes: String?
    let createdAt: Date
}

struct ReviewTaskElementInput: Codable, Equatable, Sendable {
    var snapshotId: String
    var axNodePath: String
    var commentText: String?
}

struct ReviewTaskCreateInput: Codable, Equatable, Sendable {
    var title: String?
    var instructions: String?
    var priority: String?
    var assignee: String?
    var bundleId: String?
    var snapshotIds: [String]
    var elements: [ReviewTaskElementInput]?
    var contextMarkdown: String?
}

struct ReviewTaskClaimInput: Codable, Equatable, Sendable {
    var agentId: String
}

struct ReviewTaskUpdateInput: Codable, Equatable, Sendable {
    var status: String?
    var assignee: String?
    var resultSummary: String?
    var verificationSnapshotId: String?
    var notes: String?
    var actor: String?
}

struct ReviewTaskVerificationInput: Codable, Equatable, Sendable {
    var beforeSnapshotIds: [String]?
    var afterSnapshotId: String?
    var status: String
    var notes: String?
}

struct ReviewTaskEventInput: Codable, Equatable, Sendable {
    var type: String
    var actor: String?
    var message: String
    var metadataJSON: String?
}
