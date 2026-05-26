import Foundation

/// The verdict of a `connect` smoke test: over a fixed sampling window,
/// how many binary frames arrived, their total size, and the derived
/// frame rate. `ok` is the headline — did frames actually flow — and
/// `summary` is the single line printed to the operator.
struct ConnectReport: Equatable, Sendable {
    let frames: Int
    let bytes: Int
    let seconds: Double

    /// A connection is healthy iff frames actually arrived.
    var ok: Bool { frames > 0 }

    /// Observed frame rate over the window; zero when the window had no
    /// duration (guards the divide).
    var fps: Double { seconds > 0 ? Double(frames) / seconds : 0 }

    /// Mean encoded frame size in bytes; zero when no frames arrived.
    var bytesPerFrame: Int { frames > 0 ? bytes / frames : 0 }

    var summary: String {
        "frames=\(frames) ~\(String(format: "%.1f", fps))fps \(bytesPerFrame)B/frame"
    }
}
