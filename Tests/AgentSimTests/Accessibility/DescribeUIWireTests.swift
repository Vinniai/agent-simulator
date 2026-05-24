import Testing
import Foundation
@testable import AgentSim

/// The `describe_ui` wire envelope mediates between the WebSocket
/// stream and the AX adapter. We pin the request parser and reply
/// builder here so consumers — the markup tool, the AX inspector,
/// the operator agent — can distinguish a single-node hit-test
/// result from a full-tree response without tracking request state.
@Suite("DescribeUIWire")
struct DescribeUIWireTests {

    // MARK: - parse

    @Test("parse returns nil for non-envelope lines")
    func parse_rejects_other_lines() {
        #expect(DescribeUIWire.parse("not-json") == nil)
        #expect(DescribeUIWire.parse(#"{"type":"gesture"}"#) == nil)
        #expect(DescribeUIWire.parse("{}") == nil)
    }

    @Test("parse returns Request with no point for a full-tree request")
    func parse_full_tree() {
        let req = DescribeUIWire.parse(#"{"type":"describe_ui"}"#)
        #expect(req == DescribeUIWire.Request(point: nil))
    }

    @Test("parse returns Request with point for a hit-test request")
    func parse_point() {
        let req = DescribeUIWire.parse(#"{"type":"describe_ui","x":100,"y":200}"#)
        #expect(req == DescribeUIWire.Request(point: Point(x: 100, y: 200)))
    }

    @Test("parse accepts integer x/y as well as doubles")
    func parse_point_integer() {
        let req = DescribeUIWire.parse(#"{"type":"describe_ui","x":100.5,"y":200.25}"#)
        #expect(req == DescribeUIWire.Request(point: Point(x: 100.5, y: 200.25)))
    }

    // MARK: - reply

    @Test("reply for a full-tree result carries the tree, no x/y echo")
    func reply_full_tree() {
        let tree = AXNode(role: "AXApplication", label: "Root",
                          frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 100, height: 200)))
        let reply = DescribeUIWire.reply(
            request: DescribeUIWire.Request(point: nil),
            result: tree,
            error: nil
        )
        let top = try! JSONSerialization.jsonObject(with: reply.data(using: .utf8)!) as! [String: Any]
        #expect(top["type"] as? String == "describe_ui_result")
        #expect(top["ok"] as? Bool == true)
        #expect(top["tree"] != nil)
        #expect(top["x"] == nil)
        #expect(top["y"] == nil)
    }

    @Test("reply for a hit-test result echoes the request x and y")
    func reply_point_echoes_xy() {
        let hit = AXNode(role: "AXButton", label: "Done",
                         frame: Rect(origin: Point(x: 90, y: 190), size: Size(width: 20, height: 20)))
        let reply = DescribeUIWire.reply(
            request: DescribeUIWire.Request(point: Point(x: 100, y: 200)),
            result: hit,
            error: nil
        )
        let top = try! JSONSerialization.jsonObject(with: reply.data(using: .utf8)!) as! [String: Any]
        #expect(top["ok"] as? Bool == true)
        #expect(top["x"] as? Int == 100)
        #expect(top["y"] as? Int == 200)
        #expect(top["tree"] != nil)
    }

    @Test("reply for a nil result yields ok:false with a no-data error")
    func reply_no_data() {
        let reply = DescribeUIWire.reply(
            request: DescribeUIWire.Request(point: nil),
            result: nil,
            error: nil
        )
        #expect(reply.contains(#""ok":false"#))
        #expect(reply.contains(#""error":"no accessibility data""#))
    }

    @Test("reply with an error encodes the error description and ok:false")
    func reply_error() {
        struct Boom: Error { var localizedDescription: String { "boom" } }
        let reply = DescribeUIWire.reply(
            request: DescribeUIWire.Request(point: Point(x: 1, y: 2)),
            result: nil,
            error: Boom()
        )
        #expect(reply.contains(#""ok":false"#))
        #expect(reply.contains(#""error":"#))
        // x/y still echo on error so the client correlates the failure
        // with its in-flight request.
        #expect(reply.contains(#""x":1"#))
        #expect(reply.contains(#""y":2"#))
    }
}
