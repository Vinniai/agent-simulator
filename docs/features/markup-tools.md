# Markup tools — select, brush, rectangle

The operator-facing AX inspector now exposes three drawing tools for
picking the elements a review task targets. Every tool **hits the
underlying AX tree** — markups bind to accessibility node paths, not
to pixel coordinates, so the agent receives a list of
`ReviewTaskElement` rows that survive layout shifts, retina/scale
changes, and snapshot replays.

## Where the tools live

`Resources/Web/sim-ax-inspector.js`'s sidebar grows a three-button
toolbar when **Inspect** is toggled on:

```
[ ] Inspect (hover)                          fetching…
    ┌───────────────────────────────────────┐
    │ [ Select ] [ Brush ] [ Rect ]         │   ← tool palette
    └───────────────────────────────────────┘
    (info panel for the hovered/selected node)
```

The palette appears only while inspect mode is enabled. Switching
tools clears any in-progress selection so the user can't accidentally
mix tool outputs.

## What each tool does

### Select — single-click multi-pick

Mouse-down + mouse-up at the same point: the AX hit-test under that
point becomes a selection chip. Hold **Shift / Cmd / Ctrl** to add
without clearing. Right-click on a hovered selection removes it.
Existing behaviour, unchanged.

### Brush — drag across multiple

Mouse-down → drag a path → mouse-up. Every AX element whose frame
contains *any sampled point along the path* is added to selections.
Sampling rate is 4 device-points (stroke length capped, not
mouse-event count), so the hit-test stays linear in the visible
stroke. Hold **Shift / Cmd / Ctrl** on mouse-down to add to the
existing set instead of replacing it.

### Rectangle — drag a marquee

Mouse-down at corner A → drag to corner B → mouse-up. Every AX
element whose frame *intersects* the rectangle becomes a selection.
Half-open intersection convention: `[origin, origin + size)` — same
as `CGRect.intersects` and the Swift Domain helper
`ReviewMarkupHitTest.rectangleHits`. A zero-area drag (click without
move) degrades to a single-point brush, so a "click in rectangle
mode" still picks the deepest node under the click.

## How the AX-tree binding works

Each tool produces a list of `{ path, node }` pairs where `path` is
the JSON-pointer-style breadcrumb (`/`, `/children/0`, `/children/3`)
into the AX tree. These ride the existing `AXInspector.selections`
Map and surface through `onSelectionChange`, so the queue-from-overlay
dock (`sim-selection-dock.js`) submits them as
`ReviewTaskElementInput.axNodePath` rows on `POST /reviews/:id/tasks`
without any new wiring.

When the snapshot is later re-captured (the AX tree was rebuilt — e.g.
after a Metro reload), `handleEnvelope` re-resolves persisted
selections by walking `tree.children[i]` along each stored path.
Selections whose path no longer exists are dropped silently. So
markups are durable across captures as long as the targeted node
still resolves.

## Domain mirror

The same geometry runs server-side in
`Sources/AgentSim/Domain/Review/ReviewMarkupHitTest.swift`:

```swift
ReviewMarkupHitTest.rectangleHits(rect: Rect, elements: [ReviewElement]) -> [String]
ReviewMarkupHitTest.brushHits(path: [Point], elements: [ReviewElement]) -> [String]
```

Inputs in device points, return values in AX node paths. The Swift
helpers are pure (no `Simulator`, no I/O) so they're exhaustively
unit-tested. The JS overlay implements the same algorithm in two
languages (intersection + half-open contains) — `intersectsAB` and
`containsFP` near the top of `sim-ax-inspector.js`. Keep them in
sync; the docstring on the Swift type calls this out.

## What's NOT a tool

Annotations that are *only* visual (freehand doodles, arrows,
highlights) are intentionally NOT in this iteration. The product
position is: every markup that lands on a review task should resolve
to **a list of AX elements the agent can act on**, not a decoration
the agent has to interpret. If a need for pure-visual annotations
emerges (e.g. "draw a circle around three things and just attach a
photo"), it lives in a different surface — likely an annotation
overlay layer on the review map, not the agent-bound task elements.

## Knobs / known limits

- **Sampling rate.** Brush samples every 4 device-points along the
  drag. Too sparse on very small elements (≈4×4 px buttons) — those
  may slip through the gap between samples. Mitigation: use Rectangle
  for very small targets.
- **No web-side unit tests.** The vanilla-IIFE convention means the
  JS overlay is exercised end-to-end via the browser. The Swift
  Domain helper is the testable reference; the JS is mirrored from
  the docstring. If you change one, change the other.
- **Hover tooltip during drag.** Disabled — `_handleMove` is bypassed
  while `_dragging` is true so the in-progress stroke / rectangle
  preview is the only thing visible. Hover resumes on `mouseup`.
- **No keyboard shortcut for tool switching.** A future patch could
  bind `1 / 2 / 3` to Select / Brush / Rect; left out today.
