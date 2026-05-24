import Foundation

/// Imports an externally-captured snapshot (image + optional AX tree)
/// into a review session. Parallel to `ReviewCaptureService` — both
/// write to `screenshots/<id>.jpg` and `ax/<id>.json`, and both
/// append a `ReviewScreenSnapshot` to `session.snapshots` — but this
/// path doesn't touch the simulator at all. Used by external sources
/// (agent-canvas route walkers, offline manifests, manual drops) to
/// surface artefacts in agent-sim's review map.
enum ReviewSnapshotImportService {
    static func importSnapshot(
        input: ReviewSnapshotImportInput,
        sessionId: String,
        store: any ReviewStore
    ) throws -> ReviewCaptureResult {
        let imageData = try decodeImage(input)
        let ext = fileExtension(for: input.imageMimeType)

        var session = try store.loadSession(id: sessionId)

        // Idempotency: re-importing the same external id reuses the
        // first snapshot's id and short-circuits.
        if let externalId = input.externalId,
           let existing = session.snapshots.first(where: { $0.id.hasSuffix(":\(externalId)") })
        {
            return ReviewCaptureResult(session: session, snapshot: existing, edge: nil)
        }

        let snapshotId = makeSnapshotId(externalId: input.externalId)
        let screenshotPath = "screenshots/\(snapshotId).\(ext)"
        let axPath = "ax/\(snapshotId).json"

        try store.writeArtifact(
            sessionId: sessionId, relativePath: screenshotPath, data: imageData
        )
        try store.writeArtifact(
            sessionId: sessionId,
            relativePath: axPath,
            data: Data((input.axJSON ?? "null").utf8)
        )

        let udid = input.udid ?? "imported-\(input.sourceLabel ?? "unknown")"
        if !session.devices.contains(where: { $0.udid == udid }) {
            session.devices.append(ReviewDevice(
                udid: udid,
                name: input.deviceName ?? "Imported snapshot",
                runtime: input.runtime ?? "imported"
            ))
        }

        let markers = [ReviewMarker(
            kind: .changed,
            message: "Imported snapshot\(input.sourceLabel.map { " (\($0))" } ?? "")"
        )]

        let elements = input.elements.enumerated().map { _, el in
            ReviewElement(
                id: "\(snapshotId):\(el.axNodePath)",
                snapshotId: snapshotId,
                axNodePath: el.axNodePath,
                parentPath: parentPath(for: el.axNodePath),
                role: el.role ?? "AXUnknown",
                label: el.label,
                value: el.value,
                identifier: el.identifier,
                title: el.title,
                frame: el.frame,
                depth: depth(of: el.axNodePath),
                childCount: childCount(of: el.axNodePath, in: input.elements)
            )
        }

        let snapshot = ReviewScreenSnapshot(
            id: snapshotId,
            sessionId: sessionId,
            udid: udid,
            timestamp: Date(),
            screenshotPath: screenshotPath,
            axPath: axPath,
            screenFingerprint: ReviewFingerprint.axTreeFingerprint(input.axJSON ?? "null"),
            markers: markers,
            elements: elements
        )
        session.snapshots.append(snapshot)
        try store.saveSession(session)
        return ReviewCaptureResult(session: session, snapshot: snapshot, edge: nil)
    }

    private static func decodeImage(_ input: ReviewSnapshotImportInput) throws -> Data {
        guard let data = Data(base64Encoded: input.imageBase64, options: [.ignoreUnknownCharacters]) else {
            throw ReviewSnapshotImportError.invalidBase64
        }
        guard data.count > 0 else {
            throw ReviewSnapshotImportError.invalidBase64
        }
        return data
    }

    private static func fileExtension(for mime: String) -> String {
        switch mime.lowercased() {
        case "image/png":  return "png"
        default:           return "jpg"
        }
    }

    /// Suffix the snapshot id with the external id so idempotency
    /// checks can match later imports back to the same row.
    private static func makeSnapshotId(externalId: String?) -> String {
        let base = FileReviewStore.makeID(prefix: "snap")
        guard let externalId, !externalId.isEmpty else { return base }
        return "\(base):\(externalId)"
    }

    private static func parentPath(for path: String) -> String? {
        if path == "/" { return nil }
        if let range = path.range(of: "/children/", options: .backwards) {
            let parent = String(path[..<range.lowerBound])
            return parent.isEmpty ? "/" : parent
        }
        return "/"
    }

    private static func depth(of path: String) -> Int {
        path == "/" ? 0 : path.components(separatedBy: "/children/").count - 1
    }

    private static func childCount(
        of path: String,
        in all: [ReviewSnapshotImportElement]
    ) -> Int {
        let prefix = path == "/" ? "/children/" : "\(path)/children/"
        return all.filter { other in
            other.axNodePath.hasPrefix(prefix)
                && !other.axNodePath.dropFirst(prefix.count).contains("/")
        }.count
    }
}
