import Testing
@testable import AgentSim

/// `RemoteTap` parses the `connect --tap X,Y --size WxH` flags and
/// renders the exact gesture envelope the remote serve's
/// `GestureDispatcher` parses — letting the smoke test prove the
/// upstream (browser→server) direction, not just frame flow.
@Suite("RemoteTap — outbound gesture envelope")
struct RemoteTapTests {

    @Test func `parses point and size specs`() {
        let tap = RemoteTap.parse(point: "120,340", size: "393x852")
        #expect(tap == RemoteTap(x: 120, y: 340, width: 393, height: 852))
    }

    @Test func `tolerates whitespace and uppercase X in the size`() {
        let tap = RemoteTap.parse(point: " 12 , 34 ", size: "393X852")
        #expect(tap == RemoteTap(x: 12, y: 34, width: 393, height: 852))
    }

    @Test func `renders the wire envelope the dispatcher expects`() {
        let tap = RemoteTap(x: 120, y: 340, width: 393, height: 852)
        #expect(tap.wireJSON == #"{"type":"tap","x":120,"y":340,"width":393,"height":852}"#)
    }

    @Test func `a malformed point is rejected`() {
        #expect(RemoteTap.parse(point: "120", size: "393x852") == nil)
    }

    @Test func `a malformed size is rejected`() {
        #expect(RemoteTap.parse(point: "120,340", size: "393-852") == nil)
    }
}
