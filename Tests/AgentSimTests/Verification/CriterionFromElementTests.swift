import Testing
import Foundation
@testable import AgentSim

/// Authoring shortcut for the loop: an agent captures an element it wants to
/// assert is on screen and turns it straight into an `AcceptanceCriterion`
/// rather than hand-writing the selector JSON. The factory keys on the most
/// stable handle the element offers — `identifier` (a testID) first, then the
/// visible `label` — and asserts the element `exists`. An element carrying
/// neither can't anchor an assertion, so it yields no criterion.
@Suite("AcceptanceCriterion from a captured element")
struct CriterionFromElementTests {

    private func node(identifier: String? = nil, label: String? = nil, role: String = "AXButton") -> AXNode {
        AXNode(role: role, label: label, identifier: identifier,
               frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 10, height: 10)))
    }

    @Test("an element with an identifier keys the selector on it and asserts exists")
    func keysOnIdentifier() throws {
        let c = try #require(AcceptanceCriterion.from(element: node(identifier: "tasks-fab", label: "Add")))
        #expect(c.selector.identifier == "tasks-fab")
        #expect(c.selector.label == nil)        // identifier wins; label not added
        #expect(c.expect == .exists)
        #expect(c.description.contains("tasks-fab"))
    }

    @Test("an element with no identifier falls back to its label")
    func fallsBackToLabel() throws {
        let c = try #require(AcceptanceCriterion.from(element: node(label: "Save")))
        #expect(c.selector.identifier == nil)
        #expect(c.selector.label == "Save")
        #expect(c.expect == .exists)
        #expect(c.description.contains("Save"))
    }

    @Test("an element with neither identifier nor label yields no criterion")
    func unnameableYieldsNil() {
        #expect(AcceptanceCriterion.from(element: node()) == nil)
    }

    @Test("a blank identifier/label is treated as absent, not a usable handle")
    func blankHandlesIgnored() {
        #expect(AcceptanceCriterion.from(element: node(identifier: "   ", label: "")) == nil)
    }
}
