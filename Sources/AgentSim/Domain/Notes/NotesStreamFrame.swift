import Foundation

/// Client-side decode of a single `WS /notes/stream` text frame.
///
/// The server interleaves lifecycle frames (`notes_stream_started`,
/// `notes_stream_stopped`, `notes_stream_error`) with `notes_snapshot`
/// payloads; only the snapshot carries the inbox. `notes(in:)`
/// returns that inbox (empty array for an empty snapshot) and nil for
/// anything else — a lifecycle / error / unparseable frame — so the
/// `notes watch --stream` loop can simply skip the nils. Mirrors the
/// server's `NotesStreamSnapshot` envelope.
enum NotesStreamFrame {

    /// The inbox in this frame, or nil when the frame isn't a
    /// `notes_snapshot` (lifecycle / error / non-JSON).
    static func notes(in text: String) -> [Note]? {
        guard let data = text.data(using: .utf8),
              let envelope = try? decoder.decode(Envelope.self, from: data),
              envelope.type == "notes_snapshot" else {
            return nil
        }
        return envelope.notes ?? []
    }

    private struct Envelope: Decodable {
        let type: String
        let notes: [Note]?
    }

    /// Matches the server's `.iso8601` date encoding so `Note.createdAt`
    /// round-trips off the wire.
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
