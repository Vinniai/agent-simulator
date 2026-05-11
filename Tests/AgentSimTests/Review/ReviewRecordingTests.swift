import Testing
import Foundation
@testable import AgentSim

@Suite("ReviewRecording")
struct ReviewRecordingTests {

    @Test func `recording round-trips with optional duration + snapshot links`() throws {
        let rec = ReviewRecording(
            id: "rec-1",
            sessionId: "review-abc",
            filename: "voyage-2026-05-11.webm",
            contentType: "video/webm",
            bytes: 12_512_000,
            durationSeconds: 30.5,
            fromSnapshotId: "snap-a",
            toSnapshotId: "snap-b",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try JSONEncoder().encode(rec)
        let decoded = try JSONDecoder().decode(ReviewRecording.self, from: data)

        #expect(decoded.id == rec.id)
        #expect(decoded.sessionId == rec.sessionId)
        #expect(decoded.filename == rec.filename)
        #expect(decoded.contentType == rec.contentType)
        #expect(decoded.bytes == rec.bytes)
        #expect(decoded.durationSeconds == 30.5)
        #expect(decoded.fromSnapshotId == "snap-a")
        #expect(decoded.toSnapshotId == "snap-b")
    }

    @Test func `recording survives nil duration + nil snapshot links`() throws {
        let rec = ReviewRecording(
            id: "rec-2",
            sessionId: "review-abc",
            filename: "stub.webm",
            contentType: "video/webm",
            bytes: 0,
            durationSeconds: nil,
            fromSnapshotId: nil,
            toSnapshotId: nil,
            createdAt: Date()
        )
        let data = try JSONEncoder().encode(rec)
        let decoded = try JSONDecoder().decode(ReviewRecording.self, from: data)
        #expect(decoded.durationSeconds == nil)
        #expect(decoded.fromSnapshotId == nil)
        #expect(decoded.toSnapshotId == nil)
    }

    @Test func `session carries flows + recordings collections`() throws {
        let session = ReviewSession(
            id: "review-1",
            name: "Test",
            createdAt: Date(),
            devices: [],
            snapshots: [],
            edges: [],
            comments: [],
            bundles: [],
            flows: [],
            recordings: []
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(ReviewSession.self, from: data)
        #expect(decoded.flows.isEmpty)
        #expect(decoded.recordings.isEmpty)
    }
}
