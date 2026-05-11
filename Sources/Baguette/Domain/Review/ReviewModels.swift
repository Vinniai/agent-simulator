import Foundation

struct ReviewSession: Codable, Equatable, Sendable {
    let id: String
    var name: String
    let createdAt: Date
    var devices: [ReviewDevice]
    var snapshots: [ReviewScreenSnapshot]
    var edges: [ReviewEdge]
    var comments: [ReviewElementComment]
    var bundles: [ReviewBundle]
    var flows: [ReviewFlow]
    var recordings: [ReviewRecording]

    init(
        id: String,
        name: String,
        createdAt: Date,
        devices: [ReviewDevice],
        snapshots: [ReviewScreenSnapshot],
        edges: [ReviewEdge],
        comments: [ReviewElementComment],
        bundles: [ReviewBundle],
        flows: [ReviewFlow] = [],
        recordings: [ReviewRecording] = []
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.devices = devices
        self.snapshots = snapshots
        self.edges = edges
        self.comments = comments
        self.bundles = bundles
        self.flows = flows
        self.recordings = recordings
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, devices, snapshots, edges, comments, bundles, flows, recordings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.devices = try c.decode([ReviewDevice].self, forKey: .devices)
        self.snapshots = try c.decode([ReviewScreenSnapshot].self, forKey: .snapshots)
        self.edges = try c.decode([ReviewEdge].self, forKey: .edges)
        self.comments = try c.decode([ReviewElementComment].self, forKey: .comments)
        self.bundles = try c.decode([ReviewBundle].self, forKey: .bundles)
        self.flows = try c.decodeIfPresent([ReviewFlow].self, forKey: .flows) ?? []
        self.recordings = try c.decodeIfPresent([ReviewRecording].self, forKey: .recordings) ?? []
    }
}

struct ReviewDevice: Codable, Equatable, Sendable {
    let udid: String
    let name: String
    let runtime: String
}

struct ReviewScreenSnapshot: Codable, Equatable, Sendable {
    let id: String
    let sessionId: String
    let udid: String
    let timestamp: Date
    let screenshotPath: String
    let axPath: String
    let screenFingerprint: String
    var markers: [ReviewMarker]
    var elements: [ReviewElement]?
}

struct ReviewElement: Codable, Equatable, Sendable {
    let id: String
    let snapshotId: String
    let axNodePath: String
    let parentPath: String?
    let role: String
    let label: String?
    let value: String?
    let identifier: String?
    let title: String?
    let frame: Rect
    let depth: Int
    let childCount: Int
}

struct ReviewMarker: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case duplicate
        case overlay
        case crash
        case error
        case changed
    }

    let kind: Kind
    let message: String
}

struct ReviewEdge: Codable, Equatable, Sendable {
    let id: String
    let fromSnapshotId: String?
    let toSnapshotId: String
    let actionType: String
    let axNodePath: String?
    let gestureJSON: String?
    let timestamp: Date
}

struct ReviewElementComment: Codable, Equatable, Sendable {
    let id: String
    let snapshotId: String
    let axNodePath: String
    let frame: Rect?
    let text: String
    let status: String
    let createdAt: Date
}

struct ReviewBundle: Codable, Equatable, Sendable {
    let id: String
    let createdAt: Date
    let snapshotIds: [String]
    let commentIds: [String]
    let edgeIds: [String]
    let jsonPath: String
    let markdownPath: String
}

struct ReviewCaptureInput: Codable, Equatable, Sendable {
    var udid: String
    var fromSnapshotId: String?
    var actionType: String?
    var axNodePath: String?
    var gestureJSON: String?
}

struct ReviewCommentInput: Codable, Equatable, Sendable {
    var snapshotId: String
    var axNodePath: String
    var frame: Rect?
    var text: String
    var status: String?
}

struct ReviewBundleInput: Codable, Equatable, Sendable {
    var snapshotIds: [String]
    var commentIds: [String]?
    var edgeIds: [String]?
}

struct ReviewCaptureResult: Codable, Equatable, Sendable {
    let session: ReviewSession
    let snapshot: ReviewScreenSnapshot
    let edge: ReviewEdge?
}

indirect enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSONValue")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

struct FlowStep: Codable, Equatable, Sendable {
    let type: String
    let payload: [String: JSONValue]
}

struct ReviewFlow: Codable, Equatable, Sendable {
    let id: String
    let sessionId: String
    var name: String
    var steps: [FlowStep]
    let createdAt: Date
    let createdBy: String?
}

struct ReviewRecording: Codable, Equatable, Sendable {
    let id: String
    let sessionId: String
    let filename: String
    let contentType: String
    let bytes: Int
    let durationSeconds: Double?
    let fromSnapshotId: String?
    let toSnapshotId: String?
    let createdAt: Date
}

struct ReviewFlowCreateInput: Codable, Equatable, Sendable {
    var name: String
    var steps: [FlowStep]
    var createdBy: String?
}

struct ReviewFlowReplayInput: Codable, Equatable, Sendable {
    var udid: String
    var pacing: FlowReplayPacing?
}
