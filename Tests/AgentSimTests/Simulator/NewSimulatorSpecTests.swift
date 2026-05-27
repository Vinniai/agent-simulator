import Testing
@testable import AgentSim

/// `NewSimulatorSpec.choose` is the pure half of auto-provisioning a
/// simulator: given the runtimes and device types CoreSimulator
/// advertises, decide *what* to create. The actual
/// `createDeviceWithType:runtime:name:error:` call is integration-only;
/// this picks the newest available iOS runtime and the newest iPhone so
/// the streamed device looks current.
@Suite("NewSimulatorSpec")
struct NewSimulatorSpecTests {

    @Test func `picks the newest iOS runtime and newest iPhone`() {
        let spec = NewSimulatorSpec.choose(
            name: "agent-simulator",
            runtimes: [
                (name: "iOS 17.2", identifier: "rt.iOS-17-2", available: true),
                (name: "iOS 26.5", identifier: "rt.iOS-26-5", available: true),
            ],
            deviceTypes: [
                (name: "iPhone 15",     identifier: "dt.iPhone-15"),
                (name: "iPhone 17 Pro", identifier: "dt.iPhone-17-Pro"),
            ]
        )
        #expect(spec == NewSimulatorSpec(
            name: "agent-simulator",
            runtimeIdentifier: "rt.iOS-26-5",
            deviceTypeIdentifier: "dt.iPhone-17-Pro"
        ))
    }

    @Test func `prefers the base model over Pro at the same generation`() {
        let spec = NewSimulatorSpec.choose(
            name: "agent-simulator",
            runtimes: [(name: "iOS 26.5", identifier: "rt", available: true)],
            deviceTypes: [
                (name: "iPhone 17 Pro Max", identifier: "dt.max"),
                (name: "iPhone 17 Pro",     identifier: "dt.pro"),
                (name: "iPhone 17",         identifier: "dt.base"),
            ]
        )
        #expect(spec?.deviceTypeIdentifier == "dt.base")
    }

    @Test func `ignores unavailable runtimes`() {
        let spec = NewSimulatorSpec.choose(
            name: "agent-simulator",
            runtimes: [
                (name: "iOS 27.0", identifier: "rt.future", available: false),
                (name: "iOS 26.5", identifier: "rt.now",    available: true),
            ],
            deviceTypes: [(name: "iPhone 17", identifier: "dt")]
        )
        #expect(spec?.runtimeIdentifier == "rt.now")
    }

    @Test func `ignores non-iOS runtimes`() {
        let spec = NewSimulatorSpec.choose(
            name: "agent-simulator",
            runtimes: [
                (name: "watchOS 26.0", identifier: "rt.watch", available: true),
                (name: "iOS 18.0",     identifier: "rt.ios",   available: true),
            ],
            deviceTypes: [(name: "iPhone 16", identifier: "dt")]
        )
        #expect(spec?.runtimeIdentifier == "rt.ios")
    }

    @Test func `ignores non-iPhone device types`() {
        let spec = NewSimulatorSpec.choose(
            name: "agent-simulator",
            runtimes: [(name: "iOS 26.5", identifier: "rt", available: true)],
            deviceTypes: [
                (name: "iPad Pro 11-inch (M5)", identifier: "dt.ipad"),
                (name: "iPhone 16",             identifier: "dt.phone"),
            ]
        )
        #expect(spec?.deviceTypeIdentifier == "dt.phone")
    }

    @Test func `no usable iOS runtime yields nil`() {
        #expect(NewSimulatorSpec.choose(
            name: "agent-simulator",
            runtimes: [(name: "watchOS 26.0", identifier: "rt", available: true)],
            deviceTypes: [(name: "iPhone 16", identifier: "dt")]
        ) == nil)
    }

    @Test func `no iPhone device type yields nil`() {
        #expect(NewSimulatorSpec.choose(
            name: "agent-simulator",
            runtimes: [(name: "iOS 26.5", identifier: "rt", available: true)],
            deviceTypes: [(name: "iPad Air 11-inch (M3)", identifier: "dt")]
        ) == nil)
    }
}
