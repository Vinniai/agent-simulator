# Agent Sim ↔ agent-canvas

Both projects sit in the same "capture iOS state + annotate + hand to an
agent" neighbourhood. They're solving different halves of that problem
and shouldn't be conflated.

- **agent-canvas** — *static route inventory + annotation board* for
  Expo Router apps. Walks the route list once, screenshots each, lets
  the operator draw on the resulting boards, exports a manifest the
  agent acts on out-of-band.
- **agent-simulator** — *live simulator + queued task runner* for any iOS-26
  app. Streams whatever's on-screen at 60 fps, lets the operator pick
  one accessibility element while live, queues a `ReviewTask` the
  agent claims / edits / captures-after / submits via HTTP, CLI, or
  WebSocket.

## Surface comparison

| | agent-canvas | agent-simulator |
|---|---|---|
| Language / runtime | Node ESM (~6.3 KLOC) | Swift 6.1, compiled binary (~12 KLOC Swift + ~10 KLOC web) |
| Target apps | Expo Router only (relies on `+native-intent`, deeplink scheme) | Any iOS 26 app (private SimulatorKit) |
| Storage | Filesystem (`agent-canvas/latest/manifest.json`, `<app>/agent-canvas/comments.json`) | SQLite + WAL + WS pubsub |
| Capture mode | Walks the route list, one screenshot per route via `argent open-url` | Operator-driven, off a live framebuffer stream |
| Element source | `argent native-describe-screen` OR React Native Grab paste OR inferred | Native `AXPTranslator` → `AccessibilityPlatformTranslation`, with `argent describe --json` fallback |
| Drawing tools | Rect / Pin / Circle / Arrow / Freehand / Highlight + 6 board view modes (tree, function, workflow, similar, A-Z, components) | Single-element selection on a live frame, free-text comment |
| Live framebuffer stream | None — static PNGs only | MJPEG / H.264 / AVCC at 60 fps, runtime-tunable bitrate/fps/scale |
| Input / gestures | None — capture-only; argent driven externally | Native HID via Indigo 9-arg recipe (taps, swipes, multi-finger, hardware buttons, keyboard, scroll) |
| Agent protocol | Implicit — agent reads `manifest.json` from disk | Three explicit transports: HTTP, CLI, WS (atomic claim via SQLite lock) |
| Verification loop | `verify` / `compare` scripts diff manifests | `ReviewTaskVerification` + per-task code-change tracking + reference verifier worker |
| Service mocks | Emulate integration (Google / WorkOS / Nango / Stripe) | None |
| Tests | None in the package | 449 Swift Testing cases, Chicago-school, no booted sim required |
| Web UI complexity | One SPA (~2.1 KLOC `app.js` + ~1 KLOC styles) | 24 IIFE modules per distinct feature (stream / farm / review / inspector / recorder / device-frame / …) |
| Multi-device | One device, one app | Live multi-device farm (`/farm`, every booted simulator side-by-side) |

## Where they overlap

- Both can produce *screenshot + AX element JSON + operator comment*
  for a given screen. agent-simulator via the review queue; agent-canvas via
  `capture-argent` + the canvas board.
- Both expose a local web UI for operator annotation.
- Both can call `argent` to drive the simulator (agent-canvas does
  this exclusively; agent-simulator has it as a fallback for AX-only).

## Where each pulls ahead

### agent-canvas wins on
- **Route inventory.** One pass catalogues every Expo Router route.
- **Annotation toolset.** 6 drawing tools and 6 board view modes give
  the operator a richer canvas than a single-element selector.
- **Service mocking.** Emulate integration is built in for Google /
  WorkOS / Nango / Stripe.
- **Zero-build.** `npx agent-canvas …` — no compiler chain to manage.
- **Per-route config.** `agent-canvas.config.json` carries UDID,
  bundle ID, scheme, settle ms, dev-client URL in one place.

### agent-simulator wins on
- **Live anything.** Captures bottom sheets, modals, mid-animation
  states, errors-while-typing — not just whatever routes resolve to.
- **iOS-26 input dispatch.** The real reason agent-simulator exists — the
  9-arg `IndigoHIDMessageForMouseNSEvent` from Xcode 26's preview-kit
  is the only host-side path that injects on iOS 26 reliably.
- **Gesture replay & recording.** Reusable flows you can re-run for
  regression sweeps and A/B comparisons.
- **Multi-device farm.** `/farm` streams every booted simulator
  side-by-side.
- **Formal agent protocol.** Atomic claim, status state machine,
  code-change audit, WS push, idempotent retries — eliminates the
  "did this agent grab this task already?" race.
- **Test discipline.** TDD non-negotiable, ~450 cases run without a
  booted sim, every external port is `@Mockable`.

## Positioning for agent-simulator-as-a-product

The combined workflow that uses both:

```
agent-canvas capture --capture=argent     # 1. inventory all routes (one-time)
                                          #    → produces manifest.json
operator annotates the board              # 2. notes + drawings per route
                                          #    → produces comments.json
agent reads manifest+comments, fixes      # 3. external agent driver
                                          #    via argent or agent-simulator to drive
agent-simulator serves live verification         # 4. live re-capture + visual diff
agent-simulator review-tasks verify              # 5. pass/fail back into the queue
```

If "our project" stays on top of agent-simulator, the agent-canvas pieces
worth borrowing:

1. **Route walker.** One-pass capture of every Expo Router route is
   genuinely useful and we don't have it. Plug into
   `agent-simulator review-tasks bulk-create --from-routes <manifest.json>`.
2. **Richer drawing tools.** Rect / pin / arrow / freehand are more
   expressive than the current one-element selection. Order of ~200
   LOC web work.
3. **Board view modes.** Function / workflow / components groupings
   of review tasks would help operators triage large queues. Nice
   to have, not critical.

Pieces we should *not* borrow:

- **Expo Router dependency.** agent-simulator is app-agnostic and should
  stay so.
- **File-system manifest.** SQLite already gives us atomic claim and
  WS push; we can't downgrade to JSON-on-disk.
- **Emulate service mocks.** Out of scope for a simulator tool.

## Net

agent-canvas and agent-simulator are **complements, not competitors**. The
clearest split: agent-canvas catalogues *what exists* across an Expo
Router app's surface; agent-simulator captures *what's happening right now*
and drives an agent loop against it. A team running both gets:

- *Coverage* from agent-canvas (every route inventoried at least once)
- *Liveness* from agent-simulator (whatever moment the operator wants fixed)
- *Audit* from agent-simulator (the code-change → before/after-snapshot trail
  per task)

If we were ever to merge the two, agent-simulator is the wider foundation —
agent-canvas's route walker bolts onto our queue cleanly, but our
queue doesn't bolt onto its filesystem manifest without losing the
WS / atomic-claim properties.
