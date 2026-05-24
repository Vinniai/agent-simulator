import Foundation
import Testing
import Mockable
@testable import AgentSim

/// `DoubleTapCommand.dispatch` is the testable core of the one-shot
/// double-tap: it sequences four phased `Touch1` events through `Input`
/// with an injected sleep so the iOS recognizer aggregates them into a
/// single double-tap. `run()` itself resolves a real device and stays
/// out of coverage by design.
@Suite("DoubleTapCommand")
struct DoubleTapCommandTests {

    @Test func `dispatches down, up, down, up against the input surface`() {
        let input = MockInput()
        given(input).touch1(phase: .any, at: .any, size: .any, edge: .any).willReturn(true)

        let ok = DoubleTapCommand.dispatch(
            at: Point(x: 12, y: 34), size: Size(width: 390, height: 844),
            interval: 0.05, duration: 0.08, on: input, sleep: { _ in }
        )

        #expect(ok)
        verify(input).touch1(phase: .value(.down), at: .value(Point(x: 12, y: 34)),
                             size: .value(Size(width: 390, height: 844)), edge: .value(nil)).called(2)
        verify(input).touch1(phase: .value(.up), at: .value(Point(x: 12, y: 34)),
                             size: .value(Size(width: 390, height: 844)), edge: .value(nil)).called(2)
    }

    @Test func `sleeps duration, interval, duration between the four events`() {
        let input = MockInput()
        given(input).touch1(phase: .any, at: .any, size: .any, edge: .any).willReturn(true)
        var slept: [TimeInterval] = []

        _ = DoubleTapCommand.dispatch(
            at: Point(x: 1, y: 2), size: Size(width: 100, height: 200),
            interval: 0.05, duration: 0.08, on: input, sleep: { slept.append($0) }
        )

        #expect(slept == [0.08, 0.05, 0.08])
    }

    @Test func `stops and returns false when an event fails`() {
        let input = MockInput()
        // First down succeeds, the following up fails — sequence must abort.
        given(input).touch1(phase: .value(.down), at: .any, size: .any, edge: .any).willReturn(true)
        given(input).touch1(phase: .value(.up), at: .any, size: .any, edge: .any).willReturn(false)

        let ok = DoubleTapCommand.dispatch(
            at: Point(x: 1, y: 2), size: Size(width: 100, height: 200),
            interval: 0.05, duration: 0.08, on: input, sleep: { _ in }
        )

        #expect(!ok)
        verify(input).touch1(phase: .value(.down), at: .any, size: .any, edge: .any).called(1)
    }
}
