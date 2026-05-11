import Foundation
import Testing
@testable import AgentSim

@Suite("ReviewMarkupHitTest")
struct ReviewMarkupHitTestTests {

    // Three elements at known device-point frames, mirroring the
    // visible layout of a single screen so test names read naturally.
    private static let elements: [ReviewElement] = [
        // App root — covers the whole screen.
        ReviewElement(
            id: "snap:/",
            snapshotId: "snap",
            axNodePath: "/",
            parentPath: nil,
            role: "AXApplication",
            label: "App",
            value: nil, identifier: nil, title: nil,
            frame: Rect(origin: Point(x: 0, y: 0),
                        size: Size(width: 400, height: 800)),
            depth: 0, childCount: 2
        ),
        // Header at the top.
        ReviewElement(
            id: "snap:/header",
            snapshotId: "snap",
            axNodePath: "/header",
            parentPath: "/",
            role: "AXOther",
            label: "Header",
            value: nil, identifier: nil, title: nil,
            frame: Rect(origin: Point(x: 0, y: 0),
                        size: Size(width: 400, height: 80)),
            depth: 1, childCount: 0
        ),
        // Continue button at the bottom.
        ReviewElement(
            id: "snap:/button",
            snapshotId: "snap",
            axNodePath: "/button",
            parentPath: "/",
            role: "AXButton",
            label: "Continue",
            value: nil, identifier: nil, title: nil,
            frame: Rect(origin: Point(x: 24, y: 700),
                        size: Size(width: 345, height: 50)),
            depth: 1, childCount: 0
        ),
    ]

    @Test("rectangleHits returns elements whose frames intersect the rect")
    func rectangleHitsIntersect() {
        // Rect over the header → app + header (button untouched).
        let rect = Rect(origin: Point(x: 10, y: 10),
                        size: Size(width: 200, height: 40))
        let hits = ReviewMarkupHitTest.rectangleHits(
            rect: rect, elements: Self.elements
        )
        #expect(Set(hits) == ["/", "/header"])
    }

    @Test("rectangleHits over the bottom-right hits the button + root")
    func rectangleHitsBottomRight() {
        let rect = Rect(origin: Point(x: 200, y: 720),
                        size: Size(width: 150, height: 30))
        let hits = ReviewMarkupHitTest.rectangleHits(
            rect: rect, elements: Self.elements
        )
        #expect(Set(hits) == ["/", "/button"])
    }

    @Test("rectangleHits returns an empty list when no element overlaps")
    func rectangleHitsEmpty() {
        // Way off-screen.
        let rect = Rect(origin: Point(x: 10_000, y: 10_000),
                        size: Size(width: 10, height: 10))
        let hits = ReviewMarkupHitTest.rectangleHits(
            rect: rect, elements: Self.elements
        )
        #expect(hits.isEmpty)
    }

    @Test("brushHits returns every element a stroke point lands inside")
    func brushHitsStroke() {
        // Three points: one over header, one in the middle (just root),
        // one over the button.
        let path = [
            Point(x: 100, y: 30),
            Point(x: 100, y: 400),
            Point(x: 100, y: 720),
        ]
        let hits = ReviewMarkupHitTest.brushHits(
            path: path, elements: Self.elements
        )
        #expect(Set(hits) == ["/", "/header", "/button"])
    }

    @Test("brushHits dedupes — the same element under N points appears once")
    func brushHitsDedupes() {
        let path = (0..<5).map { _ in Point(x: 100, y: 30) }
        let hits = ReviewMarkupHitTest.brushHits(
            path: path, elements: Self.elements
        )
        // App + header (the two that contain (100, 30)).
        #expect(Set(hits) == ["/", "/header"])
        #expect(hits.count == 2)
    }

    @Test("rectangleHits returns nothing when elements is empty")
    func rectangleHitsNoElements() {
        let rect = Rect(origin: Point(x: 0, y: 0),
                        size: Size(width: 100, height: 100))
        let hits = ReviewMarkupHitTest.rectangleHits(
            rect: rect, elements: []
        )
        #expect(hits.isEmpty)
    }

    @Test("rectangleHits accepts zero-area degenerate rects (single point)")
    func rectangleHitsDegenerate() {
        // A zero-area rect at (100, 30) — should behave like brushHits
        // with one point, i.e. return everything containing (100, 30).
        let rect = Rect(origin: Point(x: 100, y: 30),
                        size: Size(width: 0, height: 0))
        let hits = ReviewMarkupHitTest.rectangleHits(
            rect: rect, elements: Self.elements
        )
        #expect(Set(hits) == ["/", "/header"])
    }
}
