import Foundation

/// One tap to fire at a remote `agent-simulator serve` over the stream
/// WebSocket, so the `connect` smoke test can prove the upstream
/// (client→server) direction and not just frame flow.
///
/// Coordinates are device points, same units as `width`/`height` — the
/// wire contract `GestureDispatcher` parses on the far end. `wireJSON`
/// renders the exact `{"type":"tap",…}` envelope a browser would send.
struct RemoteTap: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    /// Parse the `--tap X,Y` and `--size WxH` flag spellings. Returns
    /// nil if either spec isn't two numbers in the expected separator.
    static func parse(point: String, size: String) -> RemoteTap? {
        let pt = point.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        let sz = size.lowercased().split(separator: "x").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard pt.count == 2, sz.count == 2,
              let x = pt[0], let y = pt[1],
              let w = sz[0], let h = sz[1] else { return nil }
        return RemoteTap(x: x, y: y, width: w, height: h)
    }

    /// The gesture envelope the remote serve's dispatcher parses. Whole
    /// numbers render without a trailing `.0` to match the browser's
    /// integer points.
    var wireJSON: String {
        "{\"type\":\"tap\",\"x\":\(Self.num(x)),\"y\":\(Self.num(y)),\"width\":\(Self.num(width)),\"height\":\(Self.num(height))}"
    }

    private static func num(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }
}
