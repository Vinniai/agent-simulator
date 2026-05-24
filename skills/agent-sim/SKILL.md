---
name: agent-sim
description: |
  Drive iOS simulators programmatically via the `agent-sim` CLI — taps, swipes,
  multi-finger gestures, hardware buttons, frame capture, all without opening
  Xcode. Use this skill when:
  (1) The agent needs to interact with a booted iOS simulator from a script
      (tap a coordinate, swipe between points, send Home / Lock / Volume /
      Action / Power, type ASCII text via the keyboard)
  (2) Building a smoke test, demo recording, or UI flow that drives a
      simulator end-to-end
  (3) Pairing iOS development with Claude Code, where the agent needs to
      verify on-screen state after a code change
  (4) User asks "tap the simulator from a script", "automate iPhone gestures",
      "control iOS sim programmatically", "drive simulator without Xcode"
  (5) User mentions `agent-sim`, `agent-sim input`, `agent-sim tap`,
      `agent-sim serve`, or `agent-sim stream` by name
  (6) An iOS smoke-test / fixture / SwiftUI verification needs to actually
      *touch* the running app, not just inspect static code
  (7) The agent needs to consume a queue of UI-review / fix tasks — poll
      `agent-sim review-tasks watch`, subscribe `WS /review-tasks/stream`,
      claim work with `review-tasks next`, and report back results /
      code-changes (the autonomous "queries come in → implement →
      verify" loop). Triggers: "poll review tasks", "task queue",
      "subscribe to review tasks over websocket", "agent-sim watch",
      "claim the next review task".
  Avoid using this skill for plain "open the iOS Simulator" / "install Xcode"
  questions — those are about Xcode itself, not about driving a sim.
---

# agent-sim — programmatic iOS simulator control

`agent-sim` is a macOS CLI that drives iOS simulators directly via Apple's
private `SimulatorHID` (the same path Xcode uses internally). It works on
**iOS 26.4 + Xcode 26 + Apple Silicon** and is faster + more reliable than
`idb` / `AXe` / `simctl io` for input.

This skill is for **agents that need to interact with a running simulator**
(taps, swipes, screenshots, gesture sequences). Humans wanting a "play the
simulator in a browser" UI should be pointed at `agent-sim serve` and
`http://localhost:8421/simulators/<udid>` — but agents drive the CLI.

## The agent's happy path

Most automation jobs follow the same shape:

```bash
# 1. Find a booted device.
agent-sim list                              # human-readable
agent-sim list --json                       # machine-readable: {running, available}

# 2. Boot one if nothing is running.
agent-sim boot --udid <UDID>

# 3. Get the screen size — you need this for every gesture.
agent-sim chrome layout --udid <UDID>       # → {composite:{width,height}, screen:{width,height}, ...}

# 4. Drive it.
agent-sim tap --udid <UDID> --x 219 --y 478 --width 438 --height 954

# 5. Verify what happened (capture one JPEG of the framebuffer).
agent-sim screenshot --udid <UDID> --output /tmp/frame.jpg
```

Steps 3–4 are the part that bites — see "The coordinate footgun" below.

## The coordinate footgun (read this)

**All `x` / `y` / `startX` / `endX` / `x1` / `x2` / `cx` / `cy` are in
device points** — same units as the `width` / `height` you pass alongside.

A "tap at the centre of an iPhone 17 Pro Max" is `x:219, y:478` (half of
**438×954**). It is **not** `x:0.5, y:0.5` (normalized). It is **not**
`x:1206, y:2622` (raw pixels). The HID adapter normalises internally.

To get the right `width` / `height` for a UDID:

```bash
agent-sim chrome layout --udid <UDID> | jq '.screen | {width, height}'
# → {"width": 438, "height": 954}
```

Always use the values from `chrome layout` — different devices have
different point sizes, and hardcoding "438×954" only works for iPhone 17
Pro Max.

## One-shot vs streaming gestures

Two ways to send input. Pick by frequency:

- **One-shot** (`agent-sim tap / swipe / pinch / pan / press`) — separate
  process per gesture. Right for a handful of distinct interactions in a
  shell script. Each invocation pays the SimulatorHID setup cost
  (~50–100ms).

- **Streaming** (`agent-sim input --udid <UDID>`) — long-running process
  reading newline-delimited JSON from stdin, writing `{"ok":true}` /
  `{"ok":false,"error":…}` to stdout per line. Right for sequences of
  many gestures (drags, multi-finger choreography, demo playback) where
  per-gesture latency matters. Same wire format the WebSocket uses.

```bash
# One-shot.
agent-sim tap --udid X --x 219 --y 478 --width 438 --height 954

# Streaming (open the pipe once, send many).
( echo '{"type":"tap","x":219,"y":478,"width":438,"height":954,"duration":0.05}'
  echo '{"type":"swipe","startX":219,"startY":760,"endX":219,"endY":190,"width":438,"height":954,"duration":0.3}'
) | agent-sim input --udid X
```

For the full wire-format spec (every gesture type with examples), read
`references/wire-protocol.md`.

## Visual verification — let the agent see what happened

After driving a UI flow, the agent usually needs to confirm state.
The right tool is `agent-sim screenshot` — a one-shot JPEG of the
simulator's framebuffer with no streaming session involved:

```bash
agent-sim screenshot --udid <UDID> --output /tmp/frame.jpg
agent-sim screenshot --udid <UDID> > /tmp/frame.jpg          # stdout works too
agent-sim screenshot --udid <UDID> --quality 0.6 --scale 2 > thumb.jpg
```

Defaults: `--quality 0.85`, `--scale 1` (native). `--scale 2` halves
each dimension; useful when you only need a quick visual check.

Equivalent HTTP route during `agent-sim serve`:
`GET http://localhost:8421/simulators/<UDID>/screenshot.jpg[?quality=][?scale=]`.

Important: SimulatorKit only emits a frame when something on screen
changes. A booted-but-idle simulator (lock screen with no second hand)
may not produce one within the 2 s timeout — `agent-sim screenshot`
exits non-zero and prints `Failure.timeout`. Wake the device with a
gesture first if you're capturing a static state:

```bash
agent-sim tap --udid <UDID> --x 1 --y 1 --width "$W" --height "$H"  # nudge
sleep 0.2
agent-sim screenshot --udid <UDID> --output /tmp/frame.jpg
```

Then `Read /tmp/frame.jpg` to inspect (Claude Code's Read tool handles
images).

For a snapshot while a `agent-sim serve` WebSocket is already open,
send `{"type":"snapshot"}` on that channel — the server emits a
keyframe immediately. Use this only when the WS is already live; for
fresh captures `agent-sim screenshot` is one HTTP-free command.

## What's wired vs what isn't

Wired (use freely):
- `tap`, `swipe`, `touch1-{down,move,up}`, `touch2-{down,move,up}`,
  `pinch`, `pan`, `scroll`. `touch1-*` events accept an optional
  `edge: "bottom" | "top" | "left" | "right"` field that flags every
  event in the chain as a screen-edge system gesture; `bottom`
  engages iOS's home-indicator recognizer (live home / app-switcher
  preview as the touches stream); `top` engages the status-bar
  recognizer (live lock-screen cover sheet from a top-left drag,
  Notification Center from a top-right drag). Omit `edge` for
  ordinary interior touches.
- `button`: `home`, `lock`, `power`, `volume-up`, `volume-down`,
  `action`, `app-switcher`, `swipe-to-app-switcher`, `swipe-to-home`,
  `pull-down-to-lock-screen`, `pull-down-to-notification-center`.
  Optional `--duration` / `"duration"` for long-press semantics
  (action button "Hold for Ring", power → Siri / SOS, …). The five
  virtual buttons land iOS gesture recognition without any
  client-side stream management. `app-switcher` fires two home
  presses ~150 ms apart (SpringBoard's own multitasking recipe);
  `swipe-to-app-switcher` is the slow drag-and-hold variant on
  the gesture path; `swipe-to-home` is the fast edge-flick → Home;
  `pull-down-to-lock-screen` and `pull-down-to-notification-center`
  drag down from top-left and top-right respectively.
- `key` (single keystroke) and `type` (US-ASCII string). CLI:
  `agent-sim key --code KeyA --modifiers shift,command --duration 0.2`
  and `agent-sim type --text "hello"`. `code` is a W3C
  `KeyboardEvent.code`; modifiers are `shift | control | option | command`.
- `describe-ui` — dump the on-screen accessibility tree as JSON
  (per-node `role`, `label`, `value`, `identifier`, `frame` in
  device points, recursive `children`). CLI:
  `agent-sim describe-ui --udid <X>` (full tree) or
  `agent-sim describe-ui --udid <X> --x <px> --y <px>` (hit-test).
  Frames are in the same units as `tap` / `swipe` wire fields, so
  reading `frame.x + frame.width/2`, `frame.y + frame.height/2`
  back into a `tap` envelope just works.
- `logs` — stream the booted simulator's unified log line-by-line
  to stdout. CLI: `agent-sim logs --udid <X> [--level info|debug|default]
  [--style default|compact|json|ndjson|syslog] [--predicate ...]
  [--bundle-id <id>]`. SIGINT (Ctrl-C) tears down cleanly. WS
  variant on `WS /simulators/<X>/logs?level=&style=&predicate=&bundleId=`
  emits `{"type":"log","line":"..."}` text frames per entry.
  Levels: only `default | info | debug` (iOS-runtime narrow — host
  `notice / error / fault` are rejected at the wire).

NOT wired (skill should NOT propose these):
- **Non-ASCII text** through `type` — IME / Pinyin / accented / emoji
  isn't on the host-HID path yet. Fall back to
  `xcrun simctl io <UDID> text "…"` for those strings, or split the
  task so only ASCII goes through `agent-sim type`.
- **F-keys, Page Up/Down, Home/End** through `key` — outside the
  phase-1 supported code set. Most iOS apps don't use them anyway.
- `button: "siri"` — crashes `backboardd` via every known path.
  Refused by the CLI.

## Composing flows — the smoke-test pattern

```bash
#!/usr/bin/env bash
set -euo pipefail
UDID="$1"

# Resolve screen size once; reuse for every gesture.
read W H < <(agent-sim chrome layout --udid "$UDID" \
  | jq -r '.screen | "\(.width) \(.height)"')

# Wake / unlock.
agent-sim press --udid "$UDID" --button lock      # toggle (sleep if awake)
sleep 0.5
agent-sim press --udid "$UDID" --button lock      # back on

# Home → tap Settings.
agent-sim press --udid "$UDID" --button home
sleep 0.4
agent-sim tap --udid "$UDID" --x $((W * 75 / 100)) --y $((H * 55 / 100)) \
              --width "$W" --height "$H"

# Capture proof.
agent-sim stream --udid "$UDID" --format mjpeg --fps 1 \
  | head -c 200000 > /tmp/settings.jpg
```

Note `width`/`height` reuse: every gesture pays the same coordinate
convention, so resolving once and re-passing avoids the footgun.

## Pairing with Claude Code

The natural loop when an agent edits a SwiftUI app:

1. Edit code → ⌘B in Xcode (or `xcodebuild`) → app reloads on the sim.
2. Agent uses `agent-sim press --button home` then `agent-sim tap …` to
   navigate to the screen it just changed.
3. Agent captures a frame (above), `Read`s the JPEG, and confirms the
   pixels match intent.

If the human wants to follow along visually, also point them at
`http://localhost:8421/simulators/<udid>` (after starting `agent-sim serve`)
— that's a focused single-tab view of the sim, no Xcode window juggling.

## The task-queue agent loop (poll / websocket)

Beyond one-off gesture driving, `agent-sim` ships a **review-task queue**:
an operator (or a bulk importer / route walker) queues work items; an
agent claims them, drives the sim to implement each, and reports results
back for verification. This is the "queries come in → implement →
verify" autonomous loop.

Two ways to learn about new work — pick by latency tolerance:

```bash
# A. POLL — one JSON line per change, dedup'd. Easiest to shell-wrap
#    (e.g. feed into a Monitor / watcher that dispatches sub-agents).
agent-sim serve &                                  # HTTP+WS on :8421
agent-sim review-tasks watch --status open         # blocks, emits on change
agent-sim review-tasks watch --status open --once  # single snapshot, exit
agent-sim review-tasks watch --session-id <id> --interval 2

# B. WEBSOCKET — server pushes, no poll loop. Subscribe + run the whole
#    loop on one socket (inbound claim/update/event accepted too).
#    WS /review-tasks/stream?status=open
#    → {"type":"task_stream_started"} → snapshot → {"type":"task_update","task":{…}}
```

Claim → implement → report (CLI mirror; every step also has an HTTP route):

```bash
TASK=$(agent-sim review-tasks next --agent-id claude-code@host | jq -r .id)
# ...drive the sim per task.elements[*].frame, edit source...
agent-sim review-tasks event  "$TASK" --type progress --actor claude-code@host --message "tapped Save"
agent-sim review-tasks add-code-change "$TASK" --path /abs/File.swift \
    --summary "fix validation" --branch "$(git branch --show-current)" \
    --diff-file /tmp/x.diff --actor claude-code@host
agent-sim review-tasks result "$TASK" --status readyForVerify \
    --summary "done" --actor claude-code@host
```

`review-tasks next` / `claim` are **atomic** against the SQLite store —
many concurrent pollers are safe, only one agent gets a given task.
Bulk-queue from an external source with `review-tasks bulk-create
--session-id <id> --file -`. Session setup + scoring gate live under
`agent-sim agent bootstrap|status|quality-gate`.

Full protocol (HTTP routes, idempotency rules, reference Python agents):
`docs/AGENT-API.md`. CLI flag-by-flag: `references/cli.md`
("review-tasks / agent"). WS frame spec: `references/wire-protocol.md`
("WS /review-tasks/stream").

> Name clash warning: an unrelated `scripts/agent-sim` Python shim may
> exist in *consumer* repos (e.g. a Convex-HTTP poller). It is **not**
> this CLI. Resolve this binary on `PATH` / via `brew` for the queue loop.

## Source triangulation + notes queue

A tap or note anchor carries an AX path; `POST /triangulate
{udid, x, y}` maps that point to ranked source-file candidates
(`{workspace: {root, framework}, candidates: [{file, line, column,
confidence, component}]}`). The browser picker fetches it once per
selection and submits the resolved envelope back with the note, so the
session-less queue (`GET /notes.json`, `WS /notes/stream`, or
`agent-sim notes watch`) hands agents the file:line directly — no
re-derivation. From the CLI, attach a pointer without a running picker
via `agent-sim notes add --udid <UDID> --text … --source
<file>:<line>[:<col>]` (e.g. from a stack trace or lint hit).
Promoted notes flow into the review-task backlog under the shared
`sessionId=notes`. See `references/wire-protocol.md` (`/triangulate`,
`/notes`) and `references/cli.md` (`notes`) for full shapes.

## Reference files

- `references/wire-protocol.md` — every gesture type with copy-pasteable
  JSON examples + the coordinate convention restated.
- `references/cli.md` — full subcommand list, flags, and exit/output
  format for each `agent-sim` command.

Read these on demand — don't pull both into context unless the task
actually needs the breadth (e.g., authoring a long input pipeline →
read `wire-protocol.md`; debugging which subcommand to use → read
`cli.md`).

## Install (only when missing)

```bash
brew install tddworks/tap/agent-sim
agent-sim --version
```

Requires Xcode 26 + Apple Silicon. If `agent-sim` already works, skip
this — agents shouldn't reinstall on every invocation.