import Testing
import Foundation
import Mockable
@testable import Baguette

@Suite("CompositeAccessibility")
struct CompositeAccessibilityTests {

    private static let nativeTree = AXNode(
        role: "AXApplication",
        label: "Native",
        frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 390, height: 844))
    )

    private static let fallbackTree = AXNode(
        role: "AXApplication",
        label: "Fallback",
        frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 390, height: 844))
    )

    private struct ThrownError: Error {}

    @Test func `describeAll prefers the primary tree when present`() throws {
        let primary = MockAccessibility()
        let fallback = MockAccessibility()
        given(primary).describeAll().willReturn(Self.nativeTree)
        given(fallback).describeAll().willReturn(Self.fallbackTree)

        let composite = CompositeAccessibility(primary: primary, fallback: fallback)

        let result = try composite.describeAll()

        #expect(result?.label == "Native")
        verify(primary).describeAll().called(1)
        verify(fallback).describeAll().called(0)
    }

    @Test func `describeAll falls back when the primary returns nil`() throws {
        let primary = MockAccessibility()
        let fallback = MockAccessibility()
        given(primary).describeAll().willReturn(nil)
        given(fallback).describeAll().willReturn(Self.fallbackTree)

        let composite = CompositeAccessibility(primary: primary, fallback: fallback)

        let result = try composite.describeAll()

        #expect(result?.label == "Fallback")
        verify(primary).describeAll().called(1)
        verify(fallback).describeAll().called(1)
    }

    @Test func `describeAll falls back when the primary throws`() throws {
        let primary = MockAccessibility()
        let fallback = MockAccessibility()
        given(primary).describeAll().willThrow(ThrownError())
        given(fallback).describeAll().willReturn(Self.fallbackTree)

        let composite = CompositeAccessibility(primary: primary, fallback: fallback)

        let result = try composite.describeAll()

        #expect(result?.label == "Fallback")
        verify(primary).describeAll().called(1)
        verify(fallback).describeAll().called(1)
    }

    @Test func `describeAll returns nil when both legs return nil`() throws {
        let primary = MockAccessibility()
        let fallback = MockAccessibility()
        given(primary).describeAll().willReturn(nil)
        given(fallback).describeAll().willReturn(nil)

        let composite = CompositeAccessibility(primary: primary, fallback: fallback)

        #expect(try composite.describeAll() == nil)
    }

    @Test func `describeAt prefers the primary hit-test when present`() throws {
        let primary = MockAccessibility()
        let fallback = MockAccessibility()
        let hit = AXNode(
            role: "AXButton", label: "OK",
            frame: Rect(origin: Point(x: 10, y: 20), size: Size(width: 80, height: 30))
        )
        given(primary).describeAt(point: .any).willReturn(hit)
        given(fallback).describeAt(point: .any).willReturn(nil)

        let composite = CompositeAccessibility(primary: primary, fallback: fallback)

        let result = try composite.describeAt(point: Point(x: 50, y: 35))

        #expect(result?.label == "OK")
        verify(primary).describeAt(point: .any).called(1)
        verify(fallback).describeAt(point: .any).called(0)
    }

    @Test func `describeAt falls back when the primary returns nil`() throws {
        let primary = MockAccessibility()
        let fallback = MockAccessibility()
        let hit = AXNode(
            role: "AXButton", label: "Submit",
            frame: Rect(origin: Point(x: 10, y: 20), size: Size(width: 80, height: 30))
        )
        given(primary).describeAt(point: .any).willReturn(nil)
        given(fallback).describeAt(point: .any).willReturn(hit)

        let composite = CompositeAccessibility(primary: primary, fallback: fallback)

        let result = try composite.describeAt(point: Point(x: 50, y: 35))

        #expect(result?.label == "Submit")
        verify(primary).describeAt(point: .any).called(1)
        verify(fallback).describeAt(point: .any).called(1)
    }

    @Test func `describeAt falls back when the primary throws`() throws {
        let primary = MockAccessibility()
        let fallback = MockAccessibility()
        let hit = AXNode(
            role: "AXButton", label: "Submit",
            frame: Rect(origin: Point(x: 10, y: 20), size: Size(width: 80, height: 30))
        )
        given(primary).describeAt(point: .any).willThrow(ThrownError())
        given(fallback).describeAt(point: .any).willReturn(hit)

        let composite = CompositeAccessibility(primary: primary, fallback: fallback)

        let result = try composite.describeAt(point: Point(x: 50, y: 35))

        #expect(result?.label == "Submit")
        verify(primary).describeAt(point: .any).called(1)
        verify(fallback).describeAt(point: .any).called(1)
    }
}
