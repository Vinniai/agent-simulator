import Foundation

/// Pure wire-format helpers for the `describe_ui` envelope sent over
/// the stream WebSocket. Parsing and reply-building both live here so
/// the Server adapter shrinks to "read line → call AX → write reply",
/// and so the markup tool / inspector / agent JS can pin the exact
/// reply shape they consume.
///
/// The reply echoes the request `x` and `y` whenever the request
/// carried them. Consumers use the echo to distinguish a single-node
/// hit-test result from a full-tree response without tracking
/// in-flight requests.
enum DescribeUIWire {

    struct Request: Equatable {
        let point: Point?
    }

    static func parse(_ line: String) -> Request? {
        guard let data = line.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (dict["type"] as? String) == "describe_ui"
        else { return nil }
        let x = (dict["x"] as? Double) ?? (dict["x"] as? Int).map(Double.init)
        let y = (dict["y"] as? Double) ?? (dict["y"] as? Int).map(Double.init)
        if let x, let y { return Request(point: Point(x: x, y: y)) }
        return Request(point: nil)
    }

    static func reply(
        request: Request,
        result: AXNode?,
        error: Error?
    ) -> String {
        let echo = request.point.map { xyJSON($0) } ?? ""
        if let error {
            let msg = jsonEscape(String(describing: error))
            return #"{"type":"describe_ui_result","ok":false,"error":"\#(msg)"\#(echo)}"#
        }
        guard let tree = result else {
            return #"{"type":"describe_ui_result","ok":false,"error":"no accessibility data"\#(echo)}"#
        }
        return #"{"type":"describe_ui_result","ok":true,"tree":\#(tree.json)\#(echo)}"#
    }

    private static func xyJSON(_ p: Point) -> String {
        ",\"x\":\(formatNumber(p.x)),\"y\":\(formatNumber(p.y))"
    }

    private static func formatNumber(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e15 {
            return String(Int(d))
        }
        return String(d)
    }

    private static func jsonEscape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(c)
            }
        }
        return out
    }
}
