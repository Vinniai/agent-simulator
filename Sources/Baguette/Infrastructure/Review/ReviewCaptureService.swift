import Foundation

enum ReviewCaptureService {
    static func capture(
        input: ReviewCaptureInput,
        sessionId: String,
        simulators: any Simulators,
        store: any ReviewStore
    ) async throws -> ReviewCaptureResult {
        guard let sim = simulators.find(udid: input.udid) else {
            throw SimulatorError.notFound(udid: input.udid)
        }

        let screenshot = try await ScreenSnapshot.capture(
            screen: sim.screen(), quality: 0.85, scale: 1
        )
        let rawAXNode = try await accessibilityTree(for: sim)
        let axNode = rawAXNode.map(ReviewAXVisibilityFilter.visibleTree)
        let axJSON = axNode?.json ?? "null"
        let snapshotId = FileReviewStore.makeID(prefix: "snap")
        let screenshotPath = "screenshots/\(snapshotId).jpg"
        let axPath = "ax/\(snapshotId).json"

        try store.writeArtifact(
            sessionId: sessionId, relativePath: screenshotPath, data: screenshot
        )
        try store.writeArtifact(
            sessionId: sessionId, relativePath: axPath, data: Data(axJSON.utf8)
        )

        var session = try store.loadSession(id: sessionId)
        if !session.devices.contains(where: { $0.udid == sim.udid }) {
            session.devices.append(ReviewDevice(
                udid: sim.udid, name: sim.name, runtime: sim.runtime
            ))
        }

        let fingerprint = ReviewFingerprint.axTreeFingerprint(axJSON)
        var markers: [ReviewMarker] = []
        if session.snapshots.contains(where: { $0.screenFingerprint == fingerprint }) {
            markers.append(ReviewMarker(
                kind: .duplicate,
                message: "AX fingerprint matches a previous snapshot"
            ))
        }
        if axNode == nil {
            markers.append(ReviewMarker(
                kind: .error,
                message: "No accessibility tree was available"
            ))
        }

        let snapshot = ReviewScreenSnapshot(
            id: snapshotId,
            sessionId: sessionId,
            udid: sim.udid,
            timestamp: Date(),
            screenshotPath: screenshotPath,
            axPath: axPath,
            screenFingerprint: fingerprint,
            markers: markers,
            elements: axNode.map { flattenElements(root: $0, snapshotId: snapshotId) } ?? []
        )
        session.snapshots.append(snapshot)

        let edge: ReviewEdge?
        if input.fromSnapshotId != nil || input.actionType != nil {
            let e = ReviewEdge(
                id: FileReviewStore.makeID(prefix: "edge"),
                fromSnapshotId: input.fromSnapshotId,
                toSnapshotId: snapshotId,
                actionType: input.actionType ?? "manual",
                axNodePath: input.axNodePath,
                gestureJSON: input.gestureJSON,
                timestamp: Date()
            )
            session.edges.append(e)
            edge = e
        } else {
            edge = nil
        }

        try store.saveSession(session)
        return ReviewCaptureResult(session: session, snapshot: snapshot, edge: edge)
    }

    private static func accessibilityTree(for sim: any Simulator) async throws -> AXNode? {
        if let native = try sim.accessibility().describeAll() {
            return native
        }
        if let fallback = try ArgentAccessibilityFallback.describeAll(udid: sim.udid) {
            return fallback
        }
        return nil
    }

    private static func flattenElements(
        root: AXNode,
        snapshotId: String
    ) -> [ReviewElement] {
        var out: [ReviewElement] = []
        func walk(_ node: AXNode, path: String, depth: Int) {
            let parentPath: String?
            if path == "/" {
                parentPath = nil
            } else if let range = path.range(of: "/children/", options: .backwards) {
                let parent = String(path[..<range.lowerBound])
                parentPath = parent.isEmpty ? "/" : parent
            } else {
                parentPath = "/"
            }
            out.append(ReviewElement(
                id: "\(snapshotId):\(path)",
                snapshotId: snapshotId,
                axNodePath: path,
                parentPath: parentPath,
                role: node.role,
                label: node.label,
                value: node.value,
                identifier: node.identifier,
                title: node.title,
                frame: node.frame,
                depth: depth,
                childCount: node.children.count
            ))
            for (index, child) in node.children.enumerated() {
                let childPath = path == "/" ? "/children/\(index)" : "\(path)/children/\(index)"
                walk(child, path: childPath, depth: depth + 1)
            }
        }
        walk(root, path: "/", depth: 0)
        return out
    }
}
