import Foundation

/// One AX element a caller is importing alongside a snapshot. Skinny
/// surface compared to `ReviewElement` — derived fields (`id`,
/// `snapshotId`, `parentPath`, `depth`, `childCount`) are filled in
/// by the import service so the caller doesn't have to compute them.
struct ReviewSnapshotImportElement: Codable, Equatable, Sendable {
    var axNodePath: String
    var role: String?
    var label: String?
    var value: String?
    var identifier: String?
    var title: String?
    var frame: Rect

    init(
        axNodePath: String,
        role: String? = nil,
        label: String? = nil,
        value: String? = nil,
        identifier: String? = nil,
        title: String? = nil,
        frame: Rect
    ) {
        self.axNodePath = axNodePath
        self.role = role
        self.label = label
        self.value = value
        self.identifier = identifier
        self.title = title
        self.frame = frame
    }
}

/// Payload for `POST /reviews/:id/snapshots/import` — used to push a
/// snapshot that wasn't captured live by agent-sim (an external tool
/// like agent-canvas, an offline screenshot the operator wants to
/// reference, etc.) into a review session.
///
/// The image is sent base64 because JSON. The verbatim `axJSON` is
/// stored on disk for archival; `elements` is the queryable
/// pre-flattened list used by drawing tools / hit-tests.
///
/// `externalId` makes the import idempotent — re-posting with the
/// same `externalId` reuses the previously-imported snapshot's id
/// instead of creating a duplicate.
struct ReviewSnapshotImportInput: Codable, Equatable, Sendable {
    var udid: String?
    var deviceName: String?
    var runtime: String?
    var imageBase64: String
    var imageMimeType: String
    var axJSON: String?
    var elements: [ReviewSnapshotImportElement]
    var sourceLabel: String?
    var externalId: String?

    init(
        udid: String? = nil,
        deviceName: String? = nil,
        runtime: String? = nil,
        imageBase64: String,
        imageMimeType: String,
        axJSON: String? = nil,
        elements: [ReviewSnapshotImportElement] = [],
        sourceLabel: String? = nil,
        externalId: String? = nil
    ) {
        self.udid = udid
        self.deviceName = deviceName
        self.runtime = runtime
        self.imageBase64 = imageBase64
        self.imageMimeType = imageMimeType
        self.axJSON = axJSON
        self.elements = elements
        self.sourceLabel = sourceLabel
        self.externalId = externalId
    }
}

enum ReviewSnapshotImportError: Error, Equatable {
    case invalidBase64
    case unsupportedMimeType(String)
}
