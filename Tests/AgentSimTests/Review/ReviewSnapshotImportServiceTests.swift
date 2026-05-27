import Foundation
import Testing
@testable import AgentSim

@Suite("ReviewSnapshotImportService")
struct ReviewSnapshotImportServiceTests {

    @Test("imports a JPEG payload with pre-flattened elements")
    func importJPEGWithElements() throws {
        let store = makeStore()
        var session = ReviewSession(
            id: "review-import-1", name: "Import test",
            createdAt: Date(),
            devices: [], snapshots: [], edges: [], comments: [], bundles: []
        )
        try store.saveSession(session)

        let oneByOneJPEG = Data([0xff, 0xd8, 0xff, 0xd9])    // minimal JPEG marker bytes
        let result = try ReviewSnapshotImportService.importSnapshot(
            input: ReviewSnapshotImportInput(
                udid: "imported-agent-canvas",
                deviceName: "Synthetic Device",
                runtime: "imported",
                imageBase64: oneByOneJPEG.base64EncodedString(),
                imageMimeType: "image/jpeg",
                axJSON: #"{"role":"AXApplication"}"#,
                elements: [
                    ReviewSnapshotImportElement(
                        axNodePath: "/",
                        role: "AXApplication",
                        label: "Home",
                        frame: Rect(origin: Point(x: 0, y: 0),
                                    size: Size(width: 393, height: 852))
                    ),
                    ReviewSnapshotImportElement(
                        axNodePath: "/children/0",
                        role: "AXButton",
                        label: "Continue",
                        frame: Rect(origin: Point(x: 24, y: 700),
                                    size: Size(width: 345, height: 50))
                    )
                ],
                sourceLabel: "agent-canvas"
            ),
            sessionId: "review-import-1",
            store: store
        )

        #expect(result.snapshot.udid == "imported-agent-canvas")
        let elements = try #require(result.snapshot.elements)
        #expect(elements.count == 2)
        #expect(elements[0].axNodePath == "/")
        #expect(elements[1].axNodePath == "/children/0")
        #expect(elements[1].role == "AXButton")
        #expect(elements[1].parentPath == "/")
        #expect(result.snapshot.markers.contains { $0.kind == .changed })

        // Session got the synthetic device + the new snapshot.
        session = try store.loadSession(id: "review-import-1")
        #expect(session.devices.contains { $0.udid == "imported-agent-canvas" })
        #expect(session.snapshots.count == 1)
        #expect(session.snapshots[0].id == result.snapshot.id)
    }

    @Test("import is idempotent on externalId when supplied")
    func importIdempotentOnExternalId() throws {
        let store = makeStore()
        let session = ReviewSession(
            id: "review-import-2", name: "",
            createdAt: Date(),
            devices: [], snapshots: [], edges: [], comments: [], bundles: []
        )
        try store.saveSession(session)

        let payload = ReviewSnapshotImportInput(
            udid: "imported",
            imageBase64: Data([0xff, 0xd8, 0xff, 0xd9]).base64EncodedString(),
            imageMimeType: "image/jpeg",
            elements: [],
            externalId: "agent-canvas:route:/home"
        )
        let first = try ReviewSnapshotImportService.importSnapshot(
            input: payload, sessionId: "review-import-2", store: store
        )
        let second = try ReviewSnapshotImportService.importSnapshot(
            input: payload, sessionId: "review-import-2", store: store
        )

        #expect(first.snapshot.id == second.snapshot.id)
        let reloaded = try store.loadSession(id: "review-import-2")
        #expect(reloaded.snapshots.count == 1)
    }

    @Test("import rejects non-base64 body")
    func importRejectsBadBase64() throws {
        let store = makeStore()
        let session = ReviewSession(
            id: "review-import-3", name: "",
            createdAt: Date(),
            devices: [], snapshots: [], edges: [], comments: [], bundles: []
        )
        try store.saveSession(session)

        let bad = ReviewSnapshotImportInput(
            udid: "imported",
            imageBase64: "not-actually-base64-data!!",
            imageMimeType: "image/jpeg",
            elements: []
        )
        #expect(throws: ReviewSnapshotImportError.self) {
            _ = try ReviewSnapshotImportService.importSnapshot(
                input: bad, sessionId: "review-import-3", store: store
            )
        }
    }

    @Test("import works with no AX JSON and zero elements (image-only)")
    func importImageOnly() throws {
        let store = makeStore()
        let session = ReviewSession(
            id: "review-import-4", name: "",
            createdAt: Date(),
            devices: [], snapshots: [], edges: [], comments: [], bundles: []
        )
        try store.saveSession(session)

        let result = try ReviewSnapshotImportService.importSnapshot(
            input: ReviewSnapshotImportInput(
                udid: "imported",
                imageBase64: Data([0xff, 0xd8, 0xff, 0xd9]).base64EncodedString(),
                imageMimeType: "image/jpeg",
                elements: []
            ),
            sessionId: "review-import-4",
            store: store
        )

        #expect(result.snapshot.elements?.isEmpty ?? true)
    }

    private func makeStore() -> FileReviewStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-simulator-snap-import-\(UUID().uuidString)")
        return FileReviewStore(root: dir)
    }
}
