import Foundation
import Testing
@testable import Baguette

@Suite("DoctorReport")
struct DoctorReportTests {

    @Test("text report renders all known fields with two-column alignment")
    func textReportRendersAllKnownFields() {
        let report = DoctorReport(
            cliVersion: "0.1.61",
            isDebugBuild: false,
            bootedSimulatorCount: 2,
            serverBase: "http://127.0.0.1:8421",
            serverReachable: true,
            serverVersion: "0.1.61"
        )

        let lines = report.textReport().split(separator: "\n").map(String.init)
        #expect(lines.contains("agent-sim doctor"))
        #expect(lines.contains("  cli version       0.1.61"))
        #expect(lines.contains("  build mode        release"))
        #expect(lines.contains("  booted sims       2"))
        #expect(lines.contains("  server            http://127.0.0.1:8421"))
        #expect(lines.contains("  server reachable  yes"))
        #expect(lines.contains("  server version    0.1.61"))
        #expect(lines.contains("  versions match    yes"))
        #expect(lines.contains("  status            healthy"))
    }

    @Test("status is drift when server version differs from cli")
    func statusReportsVersionDrift() {
        let report = DoctorReport(
            cliVersion: "0.1.70",
            isDebugBuild: false,
            bootedSimulatorCount: 1,
            serverBase: "http://127.0.0.1:8421",
            serverReachable: true,
            serverVersion: "0.1.61"
        )

        #expect(report.versionMatches == false)
        #expect(report.status == "drift")
        let text = report.textReport()
        #expect(text.contains("  versions match    no"))
        #expect(text.contains("  status            drift"))
    }

    @Test("status is offline when server unreachable")
    func statusOfflineWhenServerDown() {
        let report = DoctorReport(
            cliVersion: "0.1.70",
            isDebugBuild: true,
            bootedSimulatorCount: nil,
            serverBase: "http://127.0.0.1:8421",
            serverReachable: false,
            serverVersion: nil
        )

        #expect(report.status == "offline")
        let text = report.textReport()
        #expect(text.contains("  build mode        debug"))
        #expect(text.contains("  booted sims       unknown"))
        #expect(text.contains("  server reachable  no"))
        #expect(text.contains("  server version    -"))
        #expect(text.contains("  versions match    -"))
        #expect(text.contains("  status            offline"))
    }

    @Test("JSON encoding round-trips a fully-populated report")
    func jsonRoundtripsFullReport() throws {
        let report = DoctorReport(
            cliVersion: "0.1.70",
            isDebugBuild: true,
            bootedSimulatorCount: 3,
            serverBase: "http://127.0.0.1:8421",
            serverReachable: true,
            serverVersion: "0.1.70"
        )
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(DoctorReport.self, from: data)
        #expect(decoded == report)
    }

    @Test("versionMatches is nil when server unreachable")
    func versionMatchesNilWhenOffline() {
        let report = DoctorReport(
            cliVersion: "0.1.70",
            isDebugBuild: false,
            bootedSimulatorCount: 0,
            serverBase: "http://127.0.0.1:8421",
            serverReachable: false,
            serverVersion: nil
        )
        #expect(report.versionMatches == nil)
    }

    @Test("status is stale when server is up but predates /version endpoint")
    func statusStaleWhenServerPreVersionEndpoint() {
        let report = DoctorReport(
            cliVersion: "0.1.71",
            isDebugBuild: false,
            bootedSimulatorCount: 1,
            serverBase: "http://127.0.0.1:8421",
            serverReachable: true,
            serverVersion: nil
        )
        #expect(report.status == "stale")
        let text = report.textReport()
        #expect(text.contains("  status            stale"))
    }
}
