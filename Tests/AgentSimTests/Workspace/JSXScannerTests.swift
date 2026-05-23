import Testing
import Foundation
@testable import AgentSim

/// Static JSX scanner that ranks source candidates for a given AX hit
/// by grepping the workspace's app/ + components/ trees for the
/// node's `label`. Two heuristics in Phase B v1:
///   - JSX text node:       `<Text>Foo</Text>`            → confidence 0.8
///   - accessibilityLabel:  `accessibilityLabel="Foo"`    → confidence 0.9
/// Component name is inferred from the nearest preceding capitalized
/// tag on the same line.
///
/// The scanner is pure: file listing + reading are injected. The
/// `Triangulate.run` orchestrator wires it to disk in production.
@Suite("JSXScanner")
struct JSXScannerTests {

    private func node(role: String = "AXButton", label: String?) -> AXNode {
        AXNode(
            role: role, label: label,
            frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 1, height: 1))
        )
    }

    private let root = URL(fileURLWithPath: "/ws")

    @Test("matches a JSX text node and returns file + line + component")
    func text_node_match() {
        let file = root.appendingPathComponent("app/index.tsx")
        let candidates = JSXScanner.scan(
            node: node(label: "Mon, 18"),
            workspace: Workspace(root: root, framework: .expoRouter),
            listFiles: { _ in [file] },
            readFile: { _ in
                """
                import { Text } from 'react-native';
                export default function Home() {
                  return <Text>Mon, 18</Text>;
                }
                """
            }
        )
        #expect(candidates.count == 1)
        let c = try! #require(candidates.first)
        #expect(c.file == file)
        #expect(c.line == 3)
        #expect(c.component == "Text")
        #expect(c.confidence == 0.8)
    }

    @Test("matches accessibilityLabel with higher confidence than text")
    func ax_label_outranks_text() {
        let f1 = root.appendingPathComponent("app/a.tsx")
        let f2 = root.appendingPathComponent("app/b.tsx")
        let candidates = JSXScanner.scan(
            node: node(label: "Done"),
            workspace: Workspace(root: root, framework: .expoRouter),
            listFiles: { _ in [f1, f2] },
            readFile: { url in
                url == f1
                    ? "<Pressable accessibilityLabel=\"Done\" />"
                    : "<Text>Done</Text>"
            }
        )
        #expect(candidates.count == 2)
        #expect(candidates[0].file == f1)
        #expect(candidates[0].component == "Pressable")
        #expect(candidates[0].confidence == 0.9)
        #expect(candidates[1].file == f2)
        #expect(candidates[1].confidence == 0.8)
    }

    @Test("returns empty when node has no label")
    func no_label_no_candidates() {
        let candidates = JSXScanner.scan(
            node: node(label: nil),
            workspace: Workspace(root: root, framework: .expoRouter),
            listFiles: { _ in [root.appendingPathComponent("app/x.tsx")] },
            readFile: { _ in "<Text>Anything</Text>" }
        )
        #expect(candidates.isEmpty)
    }

    @Test("returns empty for non-expo-router workspaces")
    func only_runs_for_expo_router() {
        let candidates = JSXScanner.scan(
            node: node(label: "Done"),
            workspace: Workspace(root: root, framework: .unknown),
            listFiles: { _ in [root.appendingPathComponent("app/x.tsx")] },
            readFile: { _ in "<Text>Done</Text>" }
        )
        #expect(candidates.isEmpty)
    }

    @Test("matches multi-line JSX text where the label sits on its own line")
    func multiline_text_node() {
        let file = root.appendingPathComponent("features/home/view.tsx")
        let candidates = JSXScanner.scan(
            node: node(label: "Schedule's clear"),
            workspace: Workspace(root: root, framework: .expoRouter),
            listFiles: { _ in [file] },
            readFile: { _ in
                """
                          <Text
                            className="mt-3"
                            style={{ color: 'red' }}
                          >
                            Schedule's clear
                          </Text>
                """
            }
        )
        #expect(candidates.count == 1)
        let c = try! #require(candidates.first)
        #expect(c.line == 5)
        #expect(c.confidence == 0.8)
        #expect(c.component == "Text")
    }

    @Test("context labels nearby a hit add a per-match bonus, capped")
    func context_bonus_disambiguates() {
        // Two files both contain `<Text>Name</Text>`. Only `b.tsx` also
        // has the surrounding "Notifications" + "Settings" context the
        // AX tree picked up. Bonus pushes b above a.
        let a = root.appendingPathComponent("app/a.tsx")
        let b = root.appendingPathComponent("app/b.tsx")
        let candidates = JSXScanner.scan(
            node: node(label: "Name"),
            workspace: Workspace(root: root, framework: .expoRouter),
            context: ["Notifications", "Settings"],
            listFiles: { _ in [a, b] },
            readFile: { url in
                url == a
                    ? """
                      export function Profile() {
                        return <Text>Name</Text>;
                      }
                      """
                    : """
                      export function SettingsRow() {
                        // Settings screen
                        return (
                          <Row>
                            <Text>Notifications</Text>
                            <Text>Name</Text>
                          </Row>
                        );
                      }
                      """
            }
        )
        #expect(candidates.count == 2)
        let top = try! #require(candidates.first)
        #expect(top.file == b)
        #expect(top.confidence > 0.8)
        #expect(top.confidence <= 1.0)
        #expect(candidates[1].file == a)
        #expect(candidates[1].confidence == 0.8)
    }

    @Test("context bonus stacks per unique match and caps at +0.2")
    func context_bonus_caps() {
        let file = root.appendingPathComponent("app/x.tsx")
        let candidates = JSXScanner.scan(
            node: node(label: "Name"),
            workspace: Workspace(root: root, framework: .expoRouter),
            context: ["A", "B", "C", "D", "E"],
            listFiles: { _ in [file] },
            readFile: { _ in
                // All five context labels appear within ±20 lines.
                """
                // A B C
                // D E
                <Text>Name</Text>
                """
            }
        )
        #expect(candidates.count == 1)
        // base 0.8 + min(5 * 0.05, 0.2) = 1.0
        #expect(candidates[0].confidence == 1.0)
    }

    @Test("context labels far from the hit do not contribute")
    func context_bonus_window() {
        let file = root.appendingPathComponent("app/x.tsx")
        // Put the context label > 20 lines away from the hit.
        var lines: [String] = ["// Notifications"]
        lines.append(contentsOf: Array(repeating: "// filler", count: 30))
        lines.append("<Text>Name</Text>")
        let candidates = JSXScanner.scan(
            node: node(label: "Name"),
            workspace: Workspace(root: root, framework: .expoRouter),
            context: ["Notifications"],
            listFiles: { _ in [file] },
            readFile: { _ in lines.joined(separator: "\n") }
        )
        #expect(candidates.count == 1)
        #expect(candidates[0].confidence == 0.8)
    }

    @Test("ignores files outside .tsx/.jsx/.ts/.js")
    func extension_filter() {
        let candidates = JSXScanner.scan(
            node: node(label: "Done"),
            workspace: Workspace(root: root, framework: .expoRouter),
            listFiles: { _ in [
                root.appendingPathComponent("app/x.css"),
                root.appendingPathComponent("app/y.json"),
                root.appendingPathComponent("app/z.tsx"),
            ] },
            readFile: { _ in "<Text>Done</Text>" }
        )
        #expect(candidates.count == 1)
        #expect(candidates[0].file.lastPathComponent == "z.tsx")
    }
}
