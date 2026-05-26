import Testing
@testable import AgentSim

/// `RuntimeVersion` is the "which iOS is newest" brain behind serve's
/// auto-provisioning: when no simulator is booted we create one on the
/// *latest* runtime, and CoreSimulator hands us runtimes as display
/// names (`"iOS 26.5"`) or identifiers
/// (`"com.apple.CoreSimulator.SimRuntime.iOS-26-5"`). The version
/// compare has to be numeric — lexicographically `"iOS 9.0"` sorts
/// after `"iOS 26.5"`, which would pick the wrong runtime.
@Suite("RuntimeVersion")
struct RuntimeVersionTests {

    @Test func `parses a display name into major + minor`() {
        let v = RuntimeVersion(parsing: "iOS 26.5")
        #expect(v?.major == 26)
        #expect(v?.minor == 5)
    }

    @Test func `a bare major defaults the minor to zero`() {
        #expect(RuntimeVersion(parsing: "iOS 26") == RuntimeVersion(major: 26, minor: 0))
    }

    @Test func `parses the CoreSimulator runtime identifier form`() {
        let v = RuntimeVersion(parsing: "com.apple.CoreSimulator.SimRuntime.iOS-26-5")
        #expect(v?.major == 26)
        #expect(v?.minor == 5)
    }

    @Test func `unparseable text yields nil`() {
        #expect(RuntimeVersion(parsing: "not a version") == nil)
    }

    @Test func `compares numerically, not lexicographically`() {
        #expect(RuntimeVersion(parsing: "iOS 9.0")! < RuntimeVersion(parsing: "iOS 26.5")!)
        #expect(RuntimeVersion(parsing: "iOS 26.0")! < RuntimeVersion(parsing: "iOS 26.5")!)
        #expect(RuntimeVersion(parsing: "iOS 17.2")! < RuntimeVersion(parsing: "iOS 26.0")!)
    }

    @Test func `latest returns the newest of a mixed list`() {
        #expect(
            RuntimeVersion.latest(of: ["iOS 17.2", "iOS 26.5", "iOS 26.0"]) == "iOS 26.5"
        )
    }

    @Test func `latest ignores entries it cannot parse`() {
        #expect(
            RuntimeVersion.latest(of: ["garbage", "iOS 26.0", "also bad"]) == "iOS 26.0"
        )
    }

    @Test func `latest of an empty or all-unparseable list is nil`() {
        #expect(RuntimeVersion.latest(of: []) == nil)
        #expect(RuntimeVersion.latest(of: ["nope", "still nope"]) == nil)
    }
}
