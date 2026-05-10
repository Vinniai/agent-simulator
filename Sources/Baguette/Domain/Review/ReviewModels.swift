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
