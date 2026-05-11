# Baguette — Agent API

How an external agent (a script, an MCP server, or another autonomous
worker) drives a booted iOS-26 simulator end-to-end via baguette: claim
a queued task that names specific AX elements, open a long-lived
WebSocket to the device, tap each element by its frame, capture the
after-state, and submit a result back into the review queue for human
or downstream-agent verification.

If you're looking for the wire format of individual gestures, see
[`../README.md`](../README.md). If you're looking at the overall layer
split that puts this protocol on top of the gesture pipeline, see
[`ARCHITECTURE.md`](ARCHITECTURE.md).

## The shape of the loop

```
   ┌─────────────────────────────────────────────────────────────────┐
   │  Operator (browser /simulators/:udid or /reviews/:id)           │
   │   1. POST /reviews                          → sessionId          │
   │   2. POST /reviews/:id/capture              → before snapshot    │
   │   3. POST /reviews/:id/tasks {elements:[…]} → queued task        │
   └─────────────────────────────────────────────────────────────────┘
                                │
                                ▼  (queued, status="open")
   ┌─────────────────────────────────────────────────────────────────┐
   │  Agent                                                          │
   │   4. POST /agent/tasks/next   {agentId}     → ReviewTask | null  │
   │   5. open WS /simulators/:udid/stream?format=mjpeg               │
   │   6. for each element: send {"type":"tap", x:cx, y:cy, …}        │
   │   7. POST /agent/tasks/:id/events {progress…}   (optional, audit)│
   │   8. POST /reviews/:id/capture {fromSnapshotId} → after snapshot │
   │   9. POST /agent/tasks/:id/result               → readyForVerify │
   └─────────────────────────────────────────────────────────────────┘
                                │
                                ▼  (status="readyForVerify")
   ┌─────────────────────────────────────────────────────────────────┐
   │  Reviewer (human or downstream agent)                           │
   │  10. compares before/after via /reviews/:id (visual map)         │
   │  11. POST /review-tasks/:id/verify {status:"pass"|"fail"}        │
   └─────────────────────────────────────────────────────────────────┘
```

Every step is one HTTP / WS call. No polling-only patterns are
required: `WS /review-tasks/stream` pushes status changes for any
listener, so an agent can subscribe instead of looping on
`/agent/tasks/next` if it prefers.

The whole protocol assumes `baguette serve` is running locally; the
default base URL is `http://127.0.0.1:8421`.

## Discovery — claiming a task

```
POST /agent/tasks/next
content-type: application/json

{ "agentId": "claude-code-mcp@laptop-01" }
```

Response is either `null` (no open work for this agent) or a complete
`ReviewTask`:

```json
{
  "id": "task_01HXZ…",
  "sessionId": "review_01HXZ…",
  "title": "Fix the broken Save button",
  "instructions": "Tap Save and confirm the row appears in the list.",
  "status": "claimed",
  "assignee": "claude-code-mcp@laptop-01",
  "bundleId": "ios.com.example.MyApp",
  "elements": [
    {
      "id": "el_01HXZ…",
      "snapshotId": "snap_01HXZ…",
      "axNodePath": "/children/0/children/2",
      "role": "AXButton",
      "label": "Save",
      "frame": { "x": 270, "y": 760, "width": 80, "height": 44 }
    }
  ],
  "events": [ { "type": "created", … }, { "type": "claimed", … } ]
}
```

The crucial field is `elements[*].frame` — it carries the device-point
rectangle of each AX node at capture time, so the agent never has to
re-fetch the AX tree. Centre point is `(x + width/2, y + height/2)`.

`claimNext` is atomic against the SQLite store: only one agent receives
any given task, even with concurrent pollers. The task transitions
`open → claimed` and `assignee` is set to the supplied `agentId`.

## Execution — driving the simulator

Open one WebSocket per device and reuse it for the full session:

```
WS  /simulators/:udid/stream?format=mjpeg
```

Server → browser frames are binary (encoded video). Agent → server
frames are text JSON, one envelope per message. Same wire format as
`baguette input`; full reference in
[README "Wire protocol"](../README.md#wire-protocol--baguette-input).

For a single-finger tap on `elements[0]`:

```json
{ "type": "tap",
  "x": 310, "y": 782,
  "width": 438, "height": 954,
  "duration": 0.05 }
```

`width` and `height` are the simulator screen dimensions in device
points. Read them once per UDID from the captured snapshot's root AX
element (its `frame` is the full application bounds — i.e. the
device screen). Cache the value per UDID for the session.

The same socket carries swipes, multi-finger streaming, button
presses, scroll, keyboard. **Do not open a new socket per gesture** —
the IndigoHID pipeline has a per-session warmup; reusing one
connection per UDID is materially faster.

Inline `describe_ui` is supported on the same socket:

```json
{ "describe_ui": {} }
```

The server replies with one text frame `{"type":"describe_ui_result",
"json":"…"}` containing the live AX tree. Useful when an element's
frame may have shifted between snapshot and execution (animations,
async data load).

## Audit — emitting progress events

Optional but recommended. Each event lands in the task's `events[]`
log and is broadcast over `WS /review-tasks/stream`, so a watcher UI
can show live agent activity.

```
POST /agent/tasks/:id/events
content-type: application/json

{ "type": "progress",
  "actor": "claude-code-mcp@laptop-01",
  "message": "tapped Save, waiting 500ms for animation",
  "metadataJSON": "{\"durationMs\":500}" }
```

`type` is free-form (`progress` / `error` / `capture` / whatever you
want to filter on later). `metadataJSON`, if present, must be a valid
JSON string — the store keeps it verbatim for downstream consumers.

## Verification — capturing the after-state

```
POST /reviews/:sessionId/capture
content-type: application/json

{ "udid": "<UDID>",
  "fromSnapshotId": "snap_01HXZ…",
  "actionType": "agent" }
```

Response carries the new `ReviewCaptureResult` with `snapshot.id` —
that's what you submit as `verificationSnapshotId`.

`fromSnapshotId` and `actionType` are optional but populating them is
how the review map renders the action edge that connects before-state
to after-state. The browser's session canvas (`/reviews/:id`) shows
this as an arrow between the two snapshot tiles.

## Submission — closing out

```
POST /agent/tasks/:id/result
content-type: application/json

{ "status": "readyForVerify",
  "actor": "claude-code-mcp@laptop-01",
  "resultSummary": "Tapped Save (Submit row appeared as expected).",
  "verificationSnapshotId": "snap_01HXZ…",
  "notes": "App took ~400ms to animate; captured after settle." }
```

Status conventions: `readyForVerify` for "I think this is done, please
verify"; `failed` for "I tried and could not"; `inProgress` /
`paused` for long-running multi-step tasks. The store accepts any
string — the conventions above are what the browser map expects.

## Subscribing instead of polling

```
WS  /review-tasks/stream?status=open
WS  /review-tasks/stream?sessionId=review_01HXZ…
```

The handler immediately writes one `{"type":"task_stream_started"}`
text frame, then a snapshot of all matching tasks. Subsequent updates
arrive as `{"type":"task_update","task":{…}}`. The connection accepts
the same `claim` / `update` / `event` messages as the HTTP routes via
inbound text frames, so an agent can run the full loop on a single
socket if it prefers — see `Server.swift:1206`+ for the inbound
handler.

## CLI equivalents

Every endpoint above has a CLI mirror under `baguette review-tasks`,
suitable for shell-loop agents that prefer subprocess invocation:

```
baguette review-tasks next   --agent-id <id>           # → JSON task or null
baguette review-tasks event  <task-id> --type progress --actor <id> --message "…"
baguette review-tasks result <task-id> --status readyForVerify --summary "…" \
                                       --verification-snapshot-id snap_…
baguette review-tasks watch  --status open             # one JSON line per change
```

The HTTP and CLI paths share storage (`SQLiteReviewTaskStore`), so a
mixed setup — agent over HTTP, operator over CLI — is fine.

## Reference agent

A self-contained Python loop lives at
[`../examples/agent/baguette_worker.py`](../examples/agent/baguette_worker.py).
Copy it as a starting point for an MCP server, a CI hook, or an
autonomous-test runner. The logic is intentionally <120 lines so it's
straightforward to port to TypeScript / Go / your language of choice.

## Operational notes

- **One WebSocket per UDID, not per gesture.** The IndigoHID pipeline
  has a ~40 ms per-session warmup that should only be paid once.
- **Coordinates are device points, not normalised.** `frame` from the
  task is in points, the wire format expects points, and `width` /
  `height` in the gesture envelope are the screen size in points.
- **Auto AX fallback is transparent.** When the native AXPTranslator
  path fails (no native frameworks, host-side bridge issue), the
  capture pipeline falls back to `argent run describe --json` — no
  extra wiring on the agent side.
- **`describe_ui` is your friend mid-loop.** If an action fires an
  animation, call `describe_ui` after a settle to confirm the
  post-action AX state before proceeding.
- **Idempotency.** `POST /agent/tasks/next` is non-idempotent (it
  claims). Everything else (`event`, `result`, `verify`) is safe to
  retry — the store appends events without dedup, so retry only on
  a confirmed network failure.
