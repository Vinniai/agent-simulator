# Wire protocol — `agent-sim input` / WebSocket

Newline-delimited JSON. One gesture per line. `agent-sim input` writes
`{"ok":true}` or `{"ok":false,"error":"…"}` per line on stdout. The
WebSocket at `/simulators/<udid>/stream` accepts the same dialect.

## The coordinate convention (do not skip)

All `x`, `y`, `startX`, `startY`, `endX`, `endY`, `x1`, `y1`, `x2`, `y2`,
`cx`, `cy` are in **device points** — the same units as the `width` and
`height` you pass on the same line.

`width` and `height` come from `agent-sim chrome layout --udid <UDID>`'s
`screen.width` / `screen.height`. They are device-specific. Hardcoding
"438×954" only works for iPhone 17 Pro Max.

The wire format is **not normalized**. `x:0.5, y:0.5` will tap pixel
(0, 0) on the device. The HID adapter normalises internally on the
server side; clients always send points.

## Single-tap

```json
{"type":"tap","x":219,"y":478,"width":438,"height":954,"duration":0.05}
```

`duration` is the dwell time in seconds. Default ~0.05 if omitted.

## Swipe (one-shot, server interpolates)

```json
{"type":"swipe","startX":219,"startY":760,"endX":219,"endY":190,
                "width":438,"height":954,"duration":0.3}
```

`duration` is end-to-end. Server interpolates intermediate points; you
do not need to stream `move` events for a one-shot swipe.

## Streaming gestures (phase-driven)

Use these for real-time drags / multi-finger choreography where
intermediate samples come from a UI loop (mouse-move handler, etc.).

### One finger

```json
{"type":"touch1-down","x":219,"y":478,"width":438,"height":954}
{"type":"touch1-move","x":225,"y":485,"width":438,"height":954}
{"type":"touch1-move","x":230,"y":492,"width":438,"height":954}
{"type":"touch1-up",  "x":230,"y":492,"width":438,"height":954}
```

Pair every `down` with an `up`. `move` is optional but typically
streamed at ~60 Hz from the input source.

#### Optional `edge` field — system gesture flag

```json
{"type":"touch1-down","x":219,"y":950,"width":438,"height":954,"edge":"bottom"}
{"type":"touch1-move","x":219,"y":700,"width":438,"height":954,"edge":"bottom"}
{"type":"touch1-move","x":219,"y":500,"width":438,"height":954,"edge":"bottom"}
{"type":"touch1-up",  "x":219,"y":500,"width":438,"height":954,"edge":"bottom"}
```

`edge` accepts `bottom` / `top` / `left` / `right`. When set, every
event in the chain is flagged as an `IndigoHIDEdge` system gesture.
`bottom` engages iOS's home-indicator gesture recognizer — fast
swipe → Home, slow drag-and-hold near midpoint → App Switcher,
with iOS animating the live preview as the events stream. Omit
`edge` for ordinary interior touches. See
[`docs/features/touches.md`](../../../docs/features/touches.md) for
the full dispatch recipe.

### Two fingers (the primary pinch / pan path)

```json
{"type":"touch2-down","x1":175,"y1":478,"x2":263,"y2":478,"width":438,"height":954}
{"type":"touch2-move","x1":150,"y1":478,"x2":288,"y2":478,"width":438,"height":954}
{"type":"touch2-up",  "x1":150,"y1":478,"x2":288,"y2":478,"width":438,"height":954}
```

`UIPinchGestureRecognizer` requires two fingers. Single-finger streaming
(`touch1-*`) routes correctly but iOS treats it as an interactive pan,
not a pinch — prefer `touch2-*` for any zoom / rotate scenario.

## One-shot pinch

```json
{"type":"pinch","cx":219,"cy":478,
                "startSpread":60,"endSpread":240,
                "width":438,"height":954,"duration":0.6}
```

`cx`/`cy` is the centre of the pinch in device points. `startSpread` /
`endSpread` are the finger separation in points (60 → 240 = zoom-in).
Server interpolates 10 intermediate two-finger samples over `duration`.

## One-shot parallel pan (two fingers)

```json
{"type":"pan","x1":175,"y1":478,"x2":263,"y2":478,
              "dx":0,"dy":200,
              "width":438,"height":954,"duration":0.5}
```

Both fingers translate by `(dx, dy)` in points over `duration`. Useful
for two-finger scrolling in apps that ignore single-finger pans
(e.g., Maps).

## Scroll wheel

```json
{"type":"scroll","deltaX":0,"deltaY":-50}
```

Negative `deltaY` scrolls content up (same convention as macOS). No
`width` / `height` needed — scroll is target-agnostic.

## Hardware buttons

```json
{"type":"button","button":"home"}
{"type":"button","button":"lock"}
{"type":"button","button":"power"}
{"type":"button","button":"volume-up"}
{"type":"button","button":"volume-down"}
{"type":"button","button":"action","duration":1.2}
{"type":"button","button":"app-switcher"}
{"type":"button","button":"swipe-to-app-switcher"}
{"type":"button","button":"swipe-to-home"}
{"type":"button","button":"pull-down-to-lock-screen"}
{"type":"button","button":"pull-down-to-notification-center"}
```

Allowed names: `home | lock | power | volume-up | volume-down | action | app-switcher | swipe-to-app-switcher | swipe-to-home | pull-down-to-lock-screen | pull-down-to-notification-center`.
`duration` is the optional hold time in seconds — `0`/absent → ~100 ms
short tap; longer holds drive iOS long-press semantics ("Hold for
Ring" on `action`, Siri / SOS on `power`, etc.). The browser bezel
overlay measures real `mousedown` → `mouseup` and forwards the
elapsed time, so click-and-hold on a side button just works.

`app-switcher`, `swipe-to-app-switcher`, `swipe-to-home`,
`pull-down-to-lock-screen`, and `pull-down-to-notification-center`
are *virtual* buttons. `app-switcher` rides the home-button event
source (two `IndigoHIDMessageForButton` presses ~150 ms apart —
SpringBoard's own multitasking trigger, works on Face ID iPhones);
the other four synthesize canned system-gesture shapes
(slow drag-with-dwell up; fast edge-swipe up; slow drag down from
top-left; slow drag down from top-right). Use them when the agent
wants the gesture vocabulary without managing a streaming
`touch1-*` chain manually.
For live-preview UX, stream `touch1-*` with `edge: "bottom"` (drag
from canvas bottom — iOS animates home / app-switcher preview) or
`edge: "top"` (drag from canvas top — iOS pulls the lock-screen /
notification-center cover sheet) instead — see "One finger" above.

**Do not propose `button:"siri"`** — it crashes `backboardd` via
every known Indigo path and is rejected by the CLI before reaching
SimulatorHID.

## Keyboard

### Single keystroke

```json
{"type":"key","code":"KeyA"}
{"type":"key","code":"KeyA","modifiers":["shift"]}
{"type":"key","code":"KeyA","modifiers":["shift","command"],"duration":0.2}
{"type":"key","code":"Enter"}
```

`code` is a W3C `KeyboardEvent.code`. Supported set: `KeyA`–`KeyZ`,
`Digit0`–`Digit9`, `Enter`, `Escape`, `Backspace`, `Tab`, `Space`,
`ArrowUp`/`Down`/`Left`/`Right`, US punctuation (`Minus`, `Equal`,
`BracketLeft/Right`, `Backslash`, `Semicolon`, `Quote`, `Backquote`,
`Comma`, `Period`, `Slash`). Modifiers: `shift`, `control`, `option`,
`command`. Unknown codes / modifiers fail the parse with
`{"ok":false,"error":"…"}`.

### Typed text

```json
{"type":"type","text":"hello world"}
{"type":"type","text":"Login: alice@example.com"}
```

Decomposed at parse time into the same `(KeyboardKey, modifiers)`
pairs the wire `key` shape uses, then dispatched in order. **US ASCII
printable only** — non-ASCII (`é`, `中`, `🦄`) fails the parse rather
than silently dropping mid-string.

**Phase-1 limits:** no IME / Pinyin / dead keys / emoji / non-Latin
scripts — those need `IndigoHIDMessageForKeyboardNSEvent` (phase 2).
For non-ASCII text, fall back to `xcrun simctl io <UDID> text "…"`.

## WebSocket-only verbs (during `agent-sim serve`)

When connected to `WS /simulators/<UDID>/stream?format=…`, the same
text channel that carries gestures also accepts stream-control verbs:

```json
{"type":"set_bitrate","bps":4000000}     // re-encode target bitrate
{"type":"set_fps","fps":60}              // re-target capture rate
{"type":"set_scale","scale":1}           // 1=full, 2=half, 3=third
{"type":"force_idr"}                     // request a keyframe now
{"type":"snapshot"}                      // request one snapshot frame
{"type":"describe_ui"}                   // dump the AX tree (frontmost app)
{"type":"describe_ui","x":172,"y":880}   // hit-test the topmost AX node at a point
{"type":"stop"}                          // terminate a /logs subscription early (sent on the logs socket)
```

`describe_ui` replies on the same socket with one text frame:

```json
{ "type": "describe_ui_result", "ok": true, "tree": { /* AXNode */ } }
{ "type": "describe_ui_result", "ok": false, "error": "no accessibility data" }
```

Each `AXNode` carries `role`, `subrole`, `label`, `value`,
`identifier`, `title`, `help`, `frame` (in **device points**, same
units as `tap` / `swipe`), `enabled` / `focused` / `hidden`, and a
recursive `children` array. Use it as the structured-context
counterpart to `screenshot.jpg` — pair the screenshot with the
tree, or skip the image and act on the labels and frames directly.

These do not exist for `agent-sim input` (no stream there).

## Logs WebSocket — `WS /simulators/<UDID>/logs`

Dedicated socket for the live unified-log feed. Filter is fixed at
connect time via query string (`level`, `style`, `predicate`,
`bundleId`); restart the socket to change it.

Server → client text frames:

```json
{"type":"log_started"}
{"type":"log","line":"2026-05-06 11:56:13.835 Df locationd[5526:…] @ClxSimulated, Fix, …"}
{"type":"log_stopped","reason":"client closed"}
```

Client → server: `{"type":"stop"}` terminates early; otherwise the
socket runs until the simulator dies or the client closes. Levels:
**`default | info | debug` only** — the iOS-runtime `log` binary
rejects `notice / error / fault` (host macOS supports them; the
simulator's slimmer interface does not). For higher-severity-only
filtering, use `predicate=messageType == "error"`.

## Review-task queue WebSocket — `WS /review-tasks/stream`

The push alternative to polling `agent-sim review-tasks watch`. Filter
is fixed at connect time via query string (same filters as the CLI):

```
WS /review-tasks/stream?status=open
WS /review-tasks/stream?sessionId=review_01HXZ…
```

Server → client text frames:

```json
{"type":"task_stream_started"}
{"type":"task_update","task":{ /* full ReviewTask */ }}
```

On connect the handler writes `task_stream_started`, then a snapshot of
all matching tasks (one `task_update` per task), then a `task_update`
on every subsequent change — so a fresh subscriber is immediately
caught up without a separate list call.

Client → server: the same socket accepts the inbound loop verbs, so an
agent can claim and report on one connection instead of mixing WS +
HTTP:

```json
{"type":"claim","id":"task_01HXZ…","agentId":"claude-code@host"}
{"type":"event","id":"task_01HXZ…","eventType":"progress","actor":"claude-code@host","message":"tapped Save"}
{"type":"update","id":"task_01HXZ…","status":"readyForVerify","resultSummary":"done"}
```

Each accepted inbound frame echoes the resulting `task_update` back on
the same socket (and to every other matching subscriber), so a watcher
UI lights up with no extra wiring. Inbound shape mirrors the HTTP routes
in `docs/AGENT-API.md`; the inbound handler is `Server.swift:1206`+.

Note: this is a **different socket** from `/simulators/<udid>/stream`
(gestures + frames) and `/simulators/<udid>/logs` (unified log). The
gesture verbs above do **not** apply here, and `task_*` frames do not
appear on the simulator sockets. An agent driving the full loop opens
*both*: `/review-tasks/stream` for work, `/simulators/<udid>/stream`
for the device.

## Source triangulation — `POST /triangulate`

Maps a device-point `(x, y)` on a running app to the source file +
line that produced the screen element. Combines an AX hit-test
(same backend as `describe-ui`) with a workspace discovery
(walk-up from Metro's cwd) and a static JSX scan over the
project's source tree.

```sh
curl -sS http://localhost:8421/triangulate \
  -H 'Content-Type: application/json' \
  -d '{ "udid": "<UDID>", "x": 220, "y": 469 }'
```

Response:

```json
{
  "ok": true,
  "node": { "role": "AXStaticText", "label": "Schedule's clear", "frame": {…}, "children": [] },
  "workspace": { "root": "/Users/me/projects/mobile", "framework": "expoRouter" },
  "candidates": [
    { "file": "/Users/.../features/home/agenda-view.tsx",
      "line": 480, "column": 17,
      "confidence": 0.8, "component": "Text" }
  ]
}
```

- `node` is `null` when no AX element sits under `(x, y)`.
- `workspace` is `null` when no Metro is running for the
  simulator's frontmost app, or the project type can't be
  identified. Today only `expoRouter` produces candidates;
  other frameworks return `[]`.
- `candidates` are ranked by `confidence` in `[0, 1]`. Base tier comes
  from how the label was matched:
  - `0.9` — `accessibilityLabel="…"` matches the node label exactly
  - `0.8` — inline JSX text `>label<` or a label sitting alone on its
     own line between `>` and `<`
- Base confidence is **boosted by surrounding-context matches**: the
  server pulls the full AX tree, builds a bag of labels/values/ids
  from the hit's siblings + up to two nearest labeled ancestors, then
  for each candidate counts how many of those strings appear within
  ±20 lines. Each unique match adds `+0.05`, capped at `+0.20`, and
  clamped to `1.0`. A `<Text>Name</Text>` next to "Notifications"
  inside a "Settings" group beats the same `Name` in isolation.
- `component` is the nearest preceding capitalized JSX tag (best
  effort; can be `null`).

This is the same envelope the AX inspector panel shows in the
SOURCE row and that rides along on notes (see below) so agents
picking the queue up land on file:line directly.

## Session-less notes queue — `/notes`

A note is a one-off message left from the mobile-on-the-move
view (`/m/<UDID>`) or the `notes` CLI, optionally anchored to an
AX element. Promoting a note files it as a review task in the
shared `notes` backlog.

### POST `/notes`

```json
{
  "udid": "<UDID>",
  "text": "fix copy on agenda empty state",
  "axPath": "/window/0/text[Schedule's clear]",
  "source": {
    "workspace": { "root": "/Users/.../mobile", "framework": "expoRouter" },
    "candidates": [
      { "file": ".../agenda-view.tsx", "line": 480, "column": 17,
        "confidence": 0.8, "component": "Text" }
    ]
  }
}
```

`axPath` and `source` are both optional. The browser fills `source`
from `/triangulate` automatically; CLI clients can hand-roll it (see
`notes add --source file:line[:col]` in `references/cli.md`).

### GET `/notes.json`

Returns the inbox newest-first as a JSON array of `Note` objects
with the same shape — id / udid / text / axPath / source / promoted /
createdAt. Agents picking work up read the top candidate file:line
straight off `source.candidates[0]`.

### WS `/notes/stream`

A persistent socket that emits a `notes_snapshot` envelope on every
inbox change. Snapshot shape:

```json
{ "type": "notes_snapshot", "notes": [ <Note>, … ] }
```

Lifecycle frames (`notes_stream_started`, `notes_stream_stopped`,
`notes_stream_error`) interleave but are skipped by the
`NotesStreamFrame` decoder.

## Debugging a "tap missed"

If a tap visibly happens on the wrong spot:

1. Did you pass `width` / `height` from `chrome layout --udid <SAME-UDID>`?
   A tap with the wrong device's dimensions normalises to the wrong fraction.
2. Are coordinates in points, not pixels? iPhone 17 Pro Max screen is
   438×954 points (×3 = 1206×2622 pixels). Pixels overshoot by 3×.
3. Did the app fully load? A tap during a launch animation hits whatever
   was underneath. `sleep 0.5` after navigation is cheap insurance.