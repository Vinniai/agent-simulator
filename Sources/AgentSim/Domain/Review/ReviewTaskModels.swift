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
    var codeChanges: [ReviewTaskCodeChange]

    init(
        id: String,
        sessionId: String,
        bundleId: String?,
        title: String,
        instructions: String,
        status: String,
        priority: String,
        assignee: String?,
        contextPath: String?,
        bundleJSONPath: String?,
        bundleMarkdownPath: String?,
        resultSummary: String?,
        verificationSnapshotId: String?,
        createdAt: Date,
        updatedAt: Date,
        claimedAt: Date?,
        completedAt: Date?,
        elements: [ReviewTaskElement],
        events: [ReviewTaskEvent],
        codeChanges: [ReviewTaskCodeChange] = []
    ) {
        self.id = id
        self.sessionId = sessionId
        self.bundleId = bundleId
        self.title = title
        self.instructions = instructions
        self.status = status
        self.priority = priority
        self.assignee = assignee
        self.contextPath = contextPath
        self.bundleJSONPath = bundleJSONPath
        self.bundleMarkdownPath = bundleMarkdownPath
        self.resultSummary = resultSummary
        self.verificationSnapshotId = verificationSnapshotId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.claimedAt = claimedAt
        self.completedAt = completedAt
        self.elements = elements
        self.events = events
        self.codeChanges = codeChanges
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionId, bundleId, title, instructions, status, priority, assignee
        case contextPath, bundleJSONPath, bundleMarkdownPath
        case resultSummary, verificationSnapshotId
        case createdAt, updatedAt, claimedAt, completedAt
        case elements, events, codeChanges
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.sessionId = try c.decode(String.self, forKey: .sessionId)
        self.bundleId = try c.decodeIfPresent(String.self, forKey: .bundleId)
        self.title = try c.decode(String.self, forKey: .title)
        self.instructions = try c.decode(String.self, forKey: .instructions)
        self.status = try c.decode(String.self, forKey: .status)
        self.priority = try c.decode(String.self, forKey: .priority)
        self.assignee = try c.decodeIfPresent(String.self, forKey: .assignee)
        self.contextPath = try c.decodeIfPresent(String.self, forKey: .contextPath)
        self.bundleJSONPath = try c.decodeIfPresent(String.self, forKey: .bundleJSONPath)
        self.bundleMarkdownPath = try c.decodeIfPresent(String.self, forKey: .bundleMarkdownPath)
        self.resultSummary = try c.decodeIfPresent(String.self, forKey: .resultSummary)
        self.verificationSnapshotId = try c.decodeIfPresent(String.self, forKey: .verificationSnapshotId)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.claimedAt = try c.decodeIfPresent(Date.self, forKey: .claimedAt)
        self.completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        self.elements = try c.decode([ReviewTaskElement].self, forKey: .elements)
        self.events = try c.decode([ReviewTaskEvent].self, forKey: .events)
        self.codeChanges = try c.decodeIfPresent([ReviewTaskCodeChange].self, forKey: .codeChanges) ?? []
    }
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

struct ReviewTaskCodeChange: Codable, Equatable, Sendable {
    let id: String
    let taskId: String
    let path: String
    let summary: String?
    let startLine: Int?
    let endLine: Int?
    let commitSha: String?
    let branch: String?
    let language: String?
    let diffText: String?
    let createdAt: Date
}

struct ReviewTaskCodeChangeInput: Codable, Equatable, Sendable {
    var path: String
    var summary: String?
    var startLine: Int?
    var endLine: Int?
    var commitSha: String?
    var branch: String?
    var language: String?
    var diffText: String?
}

struct ReviewTaskCodeChangesInput: Codable, Equatable, Sendable {
    var actor: String?
    var changes: [ReviewTaskCodeChangeInput]
}

/// One row in a bulk-create batch. Skinny on purpose — bulk-create
/// does not run the bundle / context.md generation that the
/// operator-driven `POST /reviews/:id/tasks` flow does. Callers that
/// want context.md per-task can supply it via `contextMarkdown` and
/// the store will write it verbatim.
struct ReviewTaskBulkItem: Codable, Equatable, Sendable {
    var title: String?
    var instructions: String?
    var priority: String?
    var assignee: String?
    var bundleId: String?
    var elements: [ReviewTaskElementInput]
    var contextMarkdown: String?

    init(
        title: String? = nil,
        instructions: String? = nil,
        priority: String? = nil,
        assignee: String? = nil,
        bundleId: String? = nil,
        elements: [ReviewTaskElementInput] = [],
        contextMarkdown: String? = nil
    ) {
        self.title = title
        self.instructions = instructions
        self.priority = priority
        self.assignee = assignee
        self.bundleId = bundleId
        self.elements = elements
        self.contextMarkdown = contextMarkdown
    }
}

/// Defaults applied to every item in a bulk batch when the item
/// itself doesn't carry the corresponding field. Per-task explicit
/// values always win.
struct ReviewTaskBulkDefaults: Codable, Equatable, Sendable {
    var priority: String?
    var assignee: String?
    var instructions: String?
    var title: String?
}

struct ReviewTaskBulkCreateInput: Codable, Equatable, Sendable {
    var sessionId: String
    var defaults: ReviewTaskBulkDefaults?
    var tasks: [ReviewTaskBulkItem]
}

struct ReviewTaskBulkCreateError: Codable, Equatable, Sendable {
    let index: Int
    let message: String
}

/// Partial-success result. `created.count + errors.count == input.tasks.count`
/// always holds; callers know exactly which item by `index`.
struct ReviewTaskBulkCreateResult: Codable, Equatable, Sendable {
    let created: [ReviewTask]
    let errors: [ReviewTaskBulkCreateError]
}
