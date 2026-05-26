import Testing
@testable import AgentSim

/// `ConnectReport` is the verdict of a `connect` smoke test: how many
/// binary frames arrived over the sampling window, how big they were,
/// and the derived fps. `ok` is the headline — frames actually flowed —
/// and `summary` is the one line printed to the operator.
@Suite("ConnectReport — connect smoke-test verdict")
struct ConnectReportTests {

    @Test func `no frames is a failed connection`() {
        let report = ConnectReport(frames: 0, bytes: 0, seconds: 3)
        #expect(report.ok == false)
    }

    @Test func `frames flowing is a healthy connection`() {
        let report = ConnectReport(frames: 60, bytes: 180_000, seconds: 2)
        #expect(report.ok == true)
    }

    @Test func `fps is frames over the sampling window`() {
        let report = ConnectReport(frames: 60, bytes: 180_000, seconds: 2)
        #expect(report.fps == 30)
    }

    @Test func `bytes-per-frame is the mean frame size`() {
        let report = ConnectReport(frames: 60, bytes: 180_000, seconds: 2)
        #expect(report.bytesPerFrame == 3_000)
    }

    @Test func `a zero-length window reports zero fps without dividing by zero`() {
        let report = ConnectReport(frames: 5, bytes: 100, seconds: 0)
        #expect(report.fps == 0)
    }

    @Test func `summary lines up frames, fps and frame size`() {
        let report = ConnectReport(frames: 60, bytes: 180_000, seconds: 2)
        #expect(report.summary == "frames=60 ~30.0fps 3000B/frame")
    }
}
