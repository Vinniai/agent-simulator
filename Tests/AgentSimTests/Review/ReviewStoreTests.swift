import Foundation
import Testing
@testable import AgentSim

@Suite("Review store")
struct ReviewStoreTests {
    @Test func `review data defaults under the rebranded home directory`() {
        // defaultRoot honours AGENT_SIM_REVIEW_ROOT; only the no-override
        // branch carries the brand path, so skip when an override is set.
        if let override = ProcessInfo.processInfo.environment["AGENT_SIM_REVIEW_ROOT"],
           !override.isEmpty { return }
        #expect(FileReviewStore.defaultRoot().path.hasSuffix("/.agent-simulator/reviews"))
    }

    @Test func `file store persists sessions and artifacts`() throws {
        let store = FileReviewStore(root: tempRoot())
        var session = try store.createSession(name: "Checkout flow")
        session.snapshots.append(snapshot(id: "snap-1", sessionId: session.id))
        try store.saveSession(session)
        try store.writeArtifact(
            sessionId: session.id,
            relativePath: "ax/snap-1.json",
            data: Data(#"{"role":"app"}"#.utf8)
        )

        let loaded = try store.loadSession(id: session.id)
        let artifact = try store.readArtifact(
            sessionId: session.id,
            relativePath: "ax/snap-1.json"
        )

        #expect(loaded.name == "Checkout flow")
        #expect(loaded.snapshots.map(\.id) == ["snap-1"])
        #expect(String(decoding: artifact, as: UTF8.self) == #"{"role":"app"}"#)
        #expect(try store.listSessions().map(\.id) == [session.id])
    }

    @Test func `file store rejects path traversal artifacts`() throws {
        let store = FileReviewStore(root: tempRoot())
        let session = try store.createSession(name: "Security")

        #expect(throws: ReviewStoreError.invalidPath("../escape.json")) {
            try store.writeArtifact(
                sessionId: session.id,
                relativePath: "../escape.json",
                data: Data()
            )
        }
    }

    @Test func `fingerprint ignores volatile values but keeps structure`() {
        let first = """
        {"role":"window","value":"10:45","frame":{"x":0.2,"y":0,"width":100,"height":100},"children":[{"role":"button","label":"Buy","frame":{"x":10,"y":20,"width":30,"height":40},"children":[]}]}
        """
        let second = """
        {"role":"window","value":"10:46","frame":{"x":0.4,"y":0,"width":100,"height":100},"children":[{"role":"button","label":"Buy","frame":{"x":10,"y":20,"width":30,"height":40},"children":[]}]}
        """
        let changed = """
        {"role":"window","frame":{"x":0,"y":0,"width":100,"height":100},"children":[{"role":"button","label":"Sell","frame":{"x":10,"y":20,"width":30,"height":40},"children":[]}]}
        """

        #expect(ReviewFingerprint.axTreeFingerprint(first) == ReviewFingerprint.axTreeFingerprint(second))
        #expect(ReviewFingerprint.axTreeFingerprint(first) != ReviewFingerprint.axTreeFingerprint(changed))
    }

    @Test func `bundle writes JSON and markdown evidence pack`() throws {
        let store = FileReviewStore(root: tempRoot())
        var session = try store.createSession(name: "Checkout review")
        session.snapshots = [
            snapshot(id: "snap-1", sessionId: session.id),
            snapshot(id: "snap-2", sessionId: session.id),
        ]
        session.edges = [
            ReviewEdge(
                id: "edge-1",
                fromSnapshotId: "snap-1",
                toSnapshotId: "snap-2",
                actionType: "tap",
                axNodePath: "/0/1",
                gestureJSON: #"{"type":"tap"}"#,
                timestamp: Date()
            )
        ]
        session.comments = [
            ReviewElementComment(
                id: "comment-1",
                snapshotId: "snap-2",
                axNodePath: "/0/1",
                frame: nil,
                text: "Button label wraps",
                status: "open",
                createdAt: Date()
            )
        ]
        try store.saveSession(session)

        let bundle = try Server.makeReviewBundle(
            input: ReviewBundleInput(snapshotIds: ["snap-1", "snap-2"], commentIds: nil, edgeIds: nil),
            session: session,
            store: store
        )
        let markdown = try store.readArtifact(
            sessionId: session.id,
            relativePath: bundle.markdownPath
        )
        let json = try store.readArtifact(
            sessionId: session.id,
            relativePath: bundle.jsonPath
        )

        #expect(bundle.snapshotIds == ["snap-1", "snap-2"])
        #expect(String(decoding: markdown, as: UTF8.self).contains("Button label wraps"))
        #expect(String(decoding: json, as: UTF8.self).contains("edge-1"))
    }

    @Test func `argent fallback parses describe tree`() throws {
        let data = Data("""
        {
          "source": "native-devtools",
          "tree": {
            "role": "AXGroup",
            "label": "Root",
            "frame": { "x": 0, "y": 0, "width": 1, "height": 1 },
            "children": [
              {
                "role": "AXButton",
                "label": "Save",
                "identifier": "saveButton",
                "frame": { "x": 0.2, "y": 0.7, "width": 0.4, "height": 0.06 },
                "children": []
              }
            ]
          }
        }
        """.utf8)

        let parsed = try ArgentAccessibilityFallback.parseDescribeOutput(data)
        let root = try #require(parsed)

        #expect(root.role == "AXGroup")
        #expect(root.children.first?.role == "AXButton")
        #expect(root.children.first?.identifier == "saveButton")
        #expect(root.children.first?.frame.origin.x == 0.2)
    }

    @Test func `visibility filter keeps top overlay and drops background siblings`() {
        let root = AXNode(
            role: "AXApplication",
            frame: rect(0, 0, 390, 844),
            children: [
                AXNode(
                    role: "AXButton",
                    label: "Background Save",
                    identifier: "backgroundSave",
                    frame: rect(24, 740, 180, 44)
                ),
                AXNode(
                    role: "AXSheet",
                    label: "Actions Sheet",
                    frame: rect(0, 500, 390, 344),
                    children: [
                        AXNode(
                            role: "AXButton",
                            label: "Delete",
                            identifier: "deleteButton",
                            frame: rect(24, 540, 342, 48)
                        )
                    ]
                )
            ]
        )

        let filtered = ReviewAXVisibilityFilter.visibleTree(root)

        #expect(filtered.children.map(\.role) == ["AXSheet"])
        #expect(filtered.children.first?.children.first?.identifier == "deleteButton")
    }

    @Test func `visibility filter keeps leading drawer over dimmed background`() {
        let root = AXNode(
            role: "AXApplication",
            frame: rect(0, 0, 402, 874),
            children: [
                AXNode(role: "AXGenericElement", frame: rect(0, 0, 402, 785)),
                AXNode(role: "AXStaticText", label: "Conversations", frame: rect(100, 78, 154, 31)),
                AXNode(role: "AXButton", label: "Close conversations", frame: rect(352, 78, 32, 32)),
                AXNode(role: "AXGenericElement", label: "New chat", frame: rect(100, 126, 284, 45)),
                AXNode(role: "AXStaticText", label: "At your service", frame: rect(24, 78, 266, 20)),
                AXNode(role: "AXButton", label: "Ask: Weekend flight", frame: rect(16, 301, 370, 53)),
                AXNode(role: "AXGroup", label: "Assistant", frame: rect(241, 786, 80, 54)),
            ]
        )

        let filtered = ReviewAXVisibilityFilter.visibleTree(root)

        #expect(filtered.children.map(\.label) == [
            "Conversations",
            "Close conversations",
            "New chat",
        ])
    }
}

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-simulator-review-tests-\(UUID().uuidString)", isDirectory: true)
}

private func snapshot(id: String, sessionId: String) -> ReviewScreenSnapshot {
    ReviewScreenSnapshot(
        id: id,
        sessionId: sessionId,
        udid: "UDID",
        timestamp: Date(),
        screenshotPath: "screenshots/\(id).jpg",
        axPath: "ax/\(id).json",
        screenFingerprint: "fp-\(id)",
        markers: [],
        elements: []
    )
}

private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> Rect {
    Rect(origin: Point(x: x, y: y), size: Size(width: width, height: height))
}
