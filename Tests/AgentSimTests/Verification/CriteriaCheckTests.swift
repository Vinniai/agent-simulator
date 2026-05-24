import Testing
import Foundation
@testable import AgentSim

/// `CriteriaCheck` is the pure heart of first-class Acceptance Criteria
/// (ADR-0002): given an AX tree and a list of criteria, it returns one
/// `Verdict` per criterion — pass / fail / ambiguous — with no I/O and no
/// simulator. A `Selector` names an element (`identifier` > `role`+`label`
/// > `label`, ANDing whatever fields are set); an expectation asserts
/// something about the matched element. Zero matches and multiple matches
/// are reportable outcomes, never crashes.
@Suite("CriteriaCheck")
struct CriteriaCheckTests {

    private func frame(_ x: Double = 0, _ y: Double = 0, _ w: Double = 10, _ h: Double = 10) -> Rect {
        Rect(origin: Point(x: x, y: y), size: Size(width: w, height: h))
    }

    /// A representative screen: a Save button (with a testID), a disabled
    /// "Submit" button, a static text carrying an error message, and a
    /// second "Save" label on a non-button so role+label disambiguation
    /// has something to bite on.
    private func screen() -> AXNode {
        let saveButton = AXNode(
            role: "AXButton", label: "Save", identifier: "save-btn",
            frame: frame(10, 10), enabled: true
        )
        let submitButton = AXNode(
            role: "AXButton", label: "Submit",
            frame: frame(10, 30), enabled: false
        )
        let errorText = AXNode(
            role: "AXStaticText", label: "Name required",
            frame: frame(10, 50)
        )
        let saveText = AXNode(           // same label, different role
            role: "AXStaticText", label: "Save",
            frame: frame(10, 70)
        )
        let valueField = AXNode(
            role: "AXTextField", label: "Task name", value: "Buy milk",
            frame: frame(10, 90)
        )
        return AXNode(
            role: "AXWindow", label: "New Task",
            frame: frame(0, 0, 400, 800),
            children: [saveButton, submitButton, errorText, saveText, valueField]
        )
    }

    private func run(_ c: AcceptanceCriterion) -> Verdict {
        CriteriaCheck.run(tree: screen(), criteria: [c]).first!
    }

    // MARK: - selector matching

    @Test("identifier selector matches the element carrying that testID")
    func selector_identifier() {
        let v = run(AcceptanceCriterion(
            description: "save button present",
            selector: ElementSelector(identifier: "save-btn"),
            expect: .exists))
        #expect(v.outcome == .pass)
    }

    @Test("role+label selector narrows past a same-label element of another role")
    func selector_role_and_label() {
        // label "Save" appears twice; role+label pins the button.
        let v = run(AcceptanceCriterion(
            description: "Save button (not the static text) exists",
            selector: ElementSelector(role: "AXButton", label: "Save"),
            expect: .exists))
        #expect(v.outcome == .pass)
    }

    @Test("label-only selector matching nothing yields a fail for exists")
    func selector_no_match_exists_fails() {
        let v = run(AcceptanceCriterion(
            description: "a Cancel button exists",
            selector: ElementSelector(label: "Cancel"),
            expect: .exists))
        #expect(v.outcome == .fail)
    }

    // MARK: - existence

    @Test("absent passes when the selector matches nothing")
    func absent_passes_when_missing() {
        let v = run(AcceptanceCriterion(
            description: "no Delete button on this screen",
            selector: ElementSelector(label: "Delete"),
            expect: .absent))
        #expect(v.outcome == .pass)
    }

    @Test("absent fails when the element is in fact present")
    func absent_fails_when_present() {
        let v = run(AcceptanceCriterion(
            description: "error message must be gone",
            selector: ElementSelector(label: "Name required"),
            expect: .absent))
        #expect(v.outcome == .fail)
    }

    // MARK: - enabled / disabled

    @Test("enabled passes for an enabled match, fails for a disabled one")
    func enabled_expectation() {
        #expect(run(AcceptanceCriterion(
            description: "Save is enabled",
            selector: ElementSelector(identifier: "save-btn"),
            expect: .enabled)).outcome == .pass)
        #expect(run(AcceptanceCriterion(
            description: "Submit is enabled",
            selector: ElementSelector(role: "AXButton", label: "Submit"),
            expect: .enabled)).outcome == .fail)
    }

    @Test("disabled passes for the disabled Submit button")
    func disabled_expectation() {
        let v = run(AcceptanceCriterion(
            description: "Submit is disabled until valid",
            selector: ElementSelector(role: "AXButton", label: "Submit"),
            expect: .disabled))
        #expect(v.outcome == .pass)
    }

    // MARK: - text

    @Test("text equals matches against the element's label")
    func text_equals_label() {
        let v = run(AcceptanceCriterion(
            description: "error reads exactly 'Name required'",
            selector: ElementSelector(role: "AXStaticText", label: "Name required"),
            expect: .textEquals("Name required")))
        #expect(v.outcome == .pass)
    }

    @Test("text contains matches against the element's value")
    func text_contains_value() {
        let v = run(AcceptanceCriterion(
            description: "task name field contains 'milk'",
            selector: ElementSelector(role: "AXTextField", label: "Task name"),
            expect: .textContains("milk")))
        #expect(v.outcome == .pass)
    }

    // MARK: - ambiguity

    @Test("an element-level expectation over a multi-match selector is ambiguous")
    func ambiguous_on_multiple_matches() {
        // label "Save" matches two nodes; asking 'is it enabled' is undecidable.
        let v = run(AcceptanceCriterion(
            description: "the Save thing is enabled",
            selector: ElementSelector(label: "Save"),
            expect: .enabled))
        #expect(v.outcome == .ambiguous)
    }

    // MARK: - shape

    @Test("run returns one verdict per criterion, in input order")
    func one_verdict_per_criterion_in_order() {
        let criteria = [
            AcceptanceCriterion(description: "a", selector: ElementSelector(label: "Cancel"), expect: .exists), // fail
            AcceptanceCriterion(description: "b", selector: ElementSelector(identifier: "save-btn"), expect: .exists), // pass
        ]
        let verdicts = CriteriaCheck.run(tree: screen(), criteria: criteria)
        #expect(verdicts.count == 2)
        #expect(verdicts[0].outcome == .fail)
        #expect(verdicts[1].outcome == .pass)
        #expect(verdicts[0].criterion == criteria[0])
    }

    @Test("a fail verdict carries a human-readable reason")
    func fail_carries_reason() {
        let v = run(AcceptanceCriterion(
            description: "a Cancel button exists",
            selector: ElementSelector(label: "Cancel"),
            expect: .exists))
        #expect(v.reason != nil)
    }
}
