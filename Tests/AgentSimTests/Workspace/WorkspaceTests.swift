import Testing
import Foundation
@testable import AgentSim

/// A `Workspace` is the on-disk project that the simulator's frontmost
/// app was built from. We need it for source-triangulation: given an
/// AX hit and the workspace it came from, future passes will resolve
/// the underlying screen file. Phase A only pins the value type +
/// framework detection from `package.json` contents — file walking
/// and source mapping arrive in later phases.
@Suite("Workspace")
struct WorkspaceTests {

    @Test("init carries root URL and framework")
    func init_holds_fields() {
        let url = URL(fileURLWithPath: "/tmp/proj")
        let ws = Workspace(root: url, framework: .expoRouter)
        #expect(ws.root == url)
        #expect(ws.framework == .expoRouter)
    }

    @Test("detect returns .expoRouter when package.json depends on expo-router")
    func detect_expo_router_dependency() {
        let pkg = #"""
        {
          "name": "myapp",
          "dependencies": { "expo-router": "^3.4.0", "react": "18.2.0" }
        }
        """#
        #expect(Workspace.detectFramework(packageJSON: pkg) == .expoRouter)
    }

    @Test("detect returns .expoRouter when expo-router is a devDependency")
    func detect_expo_router_dev_dependency() {
        let pkg = #"""
        { "devDependencies": { "expo-router": "3.0.0" } }
        """#
        #expect(Workspace.detectFramework(packageJSON: pkg) == .expoRouter)
    }

    @Test("detect returns .unknown for unrelated React Native app")
    func detect_plain_rn() {
        let pkg = #"""
        { "dependencies": { "react-native": "0.74.0", "react": "18.2.0" } }
        """#
        #expect(Workspace.detectFramework(packageJSON: pkg) == .unknown)
    }

    @Test("detect returns .unknown for malformed JSON")
    func detect_malformed() {
        #expect(Workspace.detectFramework(packageJSON: "not json {") == .unknown)
        #expect(Workspace.detectFramework(packageJSON: "") == .unknown)
    }

    @Test("detect returns .unknown when dependencies is absent")
    func detect_no_deps() {
        #expect(Workspace.detectFramework(packageJSON: #"{"name":"x"}"#) == .unknown)
    }
}
