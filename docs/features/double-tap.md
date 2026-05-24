# Double-tap

Two taps at one coordinate, close enough together that
`UITapGestureRecognizer(numberOfTapsRequired: 2)` and SwiftUI
`TapGesture(count: 2)` both fire.

The trick is **process boundaries**. iOS aggregates taps into a
double-tap when the inter-tap delay is below the recognizer's
threshold (~0.25 s) — but two back-to-back `agent-sim tap` invocations
spend ~150–300 ms each in process startup before they even open the
HID port, which is already at or beyond the recognizer's budget. The
fix is to do the whole four-event sequence inside one process. That's
what `agent-sim double-tap` does, and that's what the four-line
`touch1-*` recipe over a single WebSocket / stdin connection does.

## Three entry points, one recipe

| Surface | Invocation |
|---------|------------|
| **CLI** (one-shot) | `agent-sim double-tap --udid <UDID> --x 220 --y 480 --width 402 --height 874 [--interval 0.05] [--duration 0.08]` |
| **Wire** (`agent-sim input` / WS) | Four lines on one connection — see below. No `{"type":"double-tap"}` envelope; the streaming primitives already cover this. |
| **Browser** | The `Resources/Web/sim-input.js` stack (`MouseGestureSource` / `TouchGestureSource`) drives the same `touch1-*` dispatcher; a JS double-click produces the same four-line sequence. |

`--interval` is the gap between tap-1-up and tap-2-down (the dwell
between the two finger lifts and re-presses). `--duration` is the hold
per tap. Defaults of `interval = 0.05` and `duration = 0.08` match
the cadence observed in working WebSocket traces from issue
[#11](https://github.com/tddworks/baguette/issues/11) (tap-1-down →
tap-1-up: ~118 ms, gap: ~49 ms, tap-2-down → tap-2-up: ~85 ms — well
inside iOS's ~250 ms aggregation window).

## CLI

```bash
agent-sim double-tap --udid <UDID> \
  --x 220 --y 480 --width 402 --height 874

# Override timing for a recognizer with non-default tapDelay:
agent-sim double-tap --udid <UDID> \
  --x 220 --y 480 --width 402 --height 874 \
  --interval 0.08 --duration 0.05
```

`x` / `y` are device points; `width` / `height` come from `agent-sim
list --json` or `agent-sim chrome layout`. Same units as every other
gesture wire envelope.

Exit code mirrors any one-shot gesture: `0` on success, `1` if the
device isn't booted / the HID dispatch fails on any of the four
events. Output is one JSON ack line:

```json
{"ok":true,"action":"double-tap"}
```

## Wire (existing `touch1-*` primitives)

`agent-sim input` and `agent-sim serve`'s WebSocket both already
support this — no new envelope. Send four lines on **one** connection:

```json
{"type":"touch1-down","x":220,"y":480,"width":402,"height":874}
{"type":"touch1-up",  "x":220,"y":480,"width":402,"height":874}
{"type":"touch1-down","x":220,"y":480,"width":402,"height":874}
{"type":"touch1-up",  "x":220,"y":480,"width":402,"height":874}
```

The timing that matters is wall-clock on the wire: each `touch1-*`
event lands on iOS as it arrives, so the cadence the agent generates
becomes the cadence the recognizer sees. A ~80 ms hold per tap and
~50 ms gap between taps is a known-good pattern; an example trace
from `agent-sim serve`:

```
11:59:16.217  touch1-down
11:59:16.335  touch1-up    (hold ≈ 118 ms)
11:59:16.384  touch1-down  (gap  ≈  49 ms)
11:59:16.469  touch1-up    (hold ≈  85 ms)
```

This is exactly what `agent-sim double-tap` produces internally — the
CLI is a convenience wrapper around the same `Touch1` dispatcher,
with `Thread.sleep` between events instead of relying on the
caller's stream timing.

## Why not a separate `Input.doubleTap` method?

We considered widening the `Input` protocol with a dedicated
`doubleTap(...)` method (so a single private-API call could
synthesize both taps). We didn't, because:

- The existing `touch1-*` path already produces the right wire
  sequence. iOS doesn't distinguish "two taps" from "one double-tap
  gesture" at the HID level — it's the recognizer's job to aggregate.
- Adding a method to `Input` would force every consumer (CLI, WS,
  `agent-sim input`) to grow a parallel envelope shape with no new
  behaviour underneath.
- The composition lives where it belongs: in the App-layer command,
  where `Thread.sleep` is allowed and the four-event recipe is a
  ~30-line sequencer easily covered by a unit test that injects a
  `MockInput` and a no-op sleep.

The implementation is `DoubleTapCommand.dispatch(...)` in
`Sources/AgentSim/App/Commands/GestureCommands.swift`. Tests live in
`Tests/AgentSimTests/App/Commands/DoubleTapCommandTests.swift`.

## Verifying against a SwiftUI recognizer

In a SwiftUI app:

```swift
Image(systemName: "heart")
    .onTapGesture(count: 2) { liked.toggle() }
```

Run a booted iPhone 17, then:

```bash
UDID=$(agent-sim list --json | jq -r '.[0].udid')
W=$(agent-sim list --json | jq -r '.[0].screen.width')
H=$(agent-sim list --json | jq -r '.[0].screen.height')
agent-sim double-tap --udid "$UDID" --x $((W / 2)) --y $((H / 2)) \
                                    --width "$W"   --height "$H"
```

The toggle should fire on the first invocation. If it doesn't,
inspect the wire: `agent-sim logs --udid "$UDID" --predicate
'process == "SpringBoard" OR process == "<your-app>"'` will show
whether the recognizer thinks it received one or two taps. The
common cause of "only one tap fires" is the **wrong device
dimensions** in `--width` / `--height` — both taps then land at the
same wrong fraction-of-screen, which the recognizer treats as one
tap because the second `down` looks like a no-op.

## Limits

- Single coordinate only. Triple-tap and N-tap recognizers aren't
  exposed — the implementation is hard-coded to two cycles. Add a
  `--count` flag if a real use case appears.
- The 0.05 s default `interval` is comfortable inside UIKit's
  default `tapDelay`, but custom recognizers with a tightened
  `maximumIntervalBetweenSuccessiveTaps` may need an explicit
  override.
- Hardware buttons that double-fire (e.g. double-press the side
  button on Apple Watch to confirm a payment) ride a different path
  — see [`buttons.md`](buttons.md). Don't reach for `double-tap` for
  them.
