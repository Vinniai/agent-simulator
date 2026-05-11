# Agent Sim — Agent API

How an external agent (a script, an MCP server, or another autonomous
worker) drives a booted iOS-26 simulator end-to-end via agent-sim: claim
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

The whole protocol assumes `agent-sim serve` is running locally; the
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
`agent-sim input`; full reference in
[README "Wire protocol"](../README.md#wire-protocol--agent-sim-input).

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

## Recording code modifications

After the agent edits source files for a task, record what changed so the
reviewer can see the original instructions, the before / after snapshots,
AND the diff that produced the after-state in one place.

```
POST /agent/tasks/:id/code-changes
content-type: application/json

{ "actor": "claude-code-mcp@laptop-01",
  "changes": [
    { "path":       "/abs/path/Sources/Save/SaveButton.swift",
      "summary":    "added validation on submit",
      "startLine":  42,
      "endLine":    58,
      "commitSha":  "abc123def",
      "branch":     "main",
      "language":   "swift",
      "diffText":   "@@ -42,7 +42,12 @@..." } ] }
```

Response is the full updated `ReviewTask` with the new `codeChanges[]`
populated (mirrors `events` / `verifySnapshotId` shape).

- **`path`** — supply an **absolute path** so the review UI's
  `vscode://file/<path>:<startLine>` link opens the file on the
  operator's machine. Relative paths still render as text but the
  link will fail to resolve.
- **`diffText`** is bounded — anything over 256 KB is truncated server
  side with a `[…truncated]` marker. Send unified-diff format.
- The operator-side mirror route is `POST /review-tasks/:id/code-changes`
  if you're driving from a non-agent tool.
- A `code_changes` event is automatically appended to the task and
  broadcast on `WS /review-tasks/stream`, so any watcher UI lights up
  without new wiring.

CLI mirror:

```
agent-sim review-tasks add-code-change <task-id> \
    --path Sources/Save/SaveButton.swift \
    --summary "added validation on submit" \
    --start-line 42 --end-line 58 \
    --commit-sha "$(git rev-parse HEAD)" \
    --branch "$(git rev-parse --abbrev-ref HEAD)" \
    --language swift \
    --diff-file /tmp/savebutton.diff \
    --actor claude-code-mcp@laptop-01

# Batch alternative — feed a JSON array of ReviewTaskCodeChangeInput:
agent-sim review-tasks add-code-change <task-id> --changes-file changes.json
```

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

Every endpoint above has a CLI mirror under `agent-sim review-tasks`,
suitable for shell-loop agents that prefer subprocess invocation:

```
agent-sim review-tasks next   --agent-id <id>           # → JSON task or null
agent-sim review-tasks event  <task-id> --type progress --actor <id> --message "…"
agent-sim review-tasks result <task-id> --status readyForVerify --summary "…" \
                                       --verification-snapshot-id snap_…
agent-sim review-tasks watch  --status open             # one JSON line per change
```

`next` and `claim` accept **`--actor` as an alias for `--agent-id`** so
the same identity flag works across every subcommand (`event`, `result`,
and `add-code-change` all use `--actor`). Either spelling is accepted on
the claim path:

```
agent-sim review-tasks next  --actor <id>      # same as --agent-id <id>
agent-sim review-tasks claim <task-id> --actor <id>
```

The HTTP and CLI paths share storage (`SQLiteReviewTaskStore`), so a
mixed setup — agent over HTTP, operator over CLI — is fine.

## Bulk-creating tasks

When an external source (a route walker, a sitemap crawler, an MCP
host) has N items it wants queued in one call, use the bulk-create
endpoint instead of N single-task POSTs:

```
POST /reviews/:sessionId/tasks/bulk
content-type: application/json

{ "sessionId":  "<ignored — path id wins>",
  "defaults":   { "priority": "normal", "assignee": "agent-import" },
  "tasks": [
    { "title": "Fix /home",   "instructions": "Re-align hero card",
      "elements": [ { "snapshotId": "snap-home",    "axNodePath": "/", "commentText": "card off-grid" } ] },
    { "title": "Fix /search", "instructions": "Move filter button right",
      "elements": [ { "snapshotId": "snap-search",  "axNodePath": "/", "commentText": null } ] }
  ] }
```

Response is a partial-success envelope so a failing row doesn't abort
the rest:

```json
{ "created": [ { "id": "task_01HX…", … }, { "id": "task_01HX…", … } ],
  "errors":  [ { "index": 7, "message": "title is blank and no default supplied" } ] }
```

`created.count + errors.count` always equals `tasks.count` so the
caller knows exactly which item failed. The route does NOT generate
per-task bundles or `context.md` files — the single-task interactive
flow keeps the bundle machinery. Use bulk-create for external
ingestion (route walker, sitemap, manifest); use single-create when
the operator is interactively marking up live captures.

## Importing external snapshots

Sometimes the artefacts arrive from somewhere other than agent-sim
itself — a route walker that owns its own screenshotter, an offline
manifest, a manual drop. Push them in with:

```
POST /reviews/:sessionId/snapshots/import
content-type: application/json

{ "udid":          "imported-agent-canvas",
  "deviceName":    "Synthetic Device",
  "runtime":       "imported",
  "imageBase64":   "<base64 JPEG or PNG bytes>",
  "imageMimeType": "image/jpeg",
  "axJSON":        "{\"role\":\"AXApplication\",…}",   // optional verbatim AX tree
  "elements": [
    { "axNodePath": "/", "role": "AXApplication", "label": "Home",
      "frame": { "x": 0, "y": 0, "width": 393, "height": 852 } },
    { "axNodePath": "/children/0", "role": "AXButton", "label": "Continue",
      "frame": { "x": 24, "y": 700, "width": 345, "height": 50 } }
  ],
  "sourceLabel": "agent-canvas",
  "externalId":  "route:/home" }
```

The response is the same `ReviewCaptureResult` shape as the live
capture path — `{session, snapshot, edge:null}`. The snapshot is
written to `~/.agent-sim/reviews/<sessionId>/screenshots/<id>.jpg` and
`<id>.json` for AX, just like a live capture, so the review browser
renders them identically.

- **`externalId` makes the import idempotent.** Re-posting with the
  same `externalId` reuses the previously-imported snapshot's id
  instead of creating a duplicate. Useful when the same agent-canvas
  manifest is replayed.
- **`elements` is queryable**; `axJSON` is verbatim archival. Supply
  both for the richest review surface. `axJSON` alone is allowed (the
  drawing tools won't have per-element hit-tests but the verbatim
  tree is still on disk for reference).
- **`udid`** is synthesised from `sourceLabel` if absent
  (e.g. `imported-agent-canvas`). The review map shows one synthetic
  "device" tile per source so external snapshots don't collide with
  live ones.

CLI mirror — pipe a JSON file or stream from stdin:

```bash
agent-sim review-tasks bulk-create \
    --session-id review_01HX… \
    --file path/to/tasks.json \
    --assignee agent-import \
    --priority high

# Stdin form — handy with adapters that emit the envelope.
agent_canvas_to_baguette --manifest agent-canvas/latest/manifest.json \
                         --session-id review_01HX… \
    | agent-sim review-tasks bulk-create --session-id review_01HX… --file -
```

CLI overrides (`--assignee` / `--priority` / `--title` / `--instructions`)
win over file-level `defaults` so an operator can re-tag a batch
without rewriting the JSON.

## Reference agents

Two self-contained Python loops ship in the repo:

- [`../examples/agent/baguette_worker.py`](../examples/agent/baguette_worker.py)
  — claims a task, drives the simulator over WebSocket, captures the
  after-state, submits a result. <200 LOC, stdlib + `websocket-client`.
- [`../examples/agent/baguette_verifier.py`](../examples/agent/baguette_verifier.py)
  — polls `readyForVerify` submissions from a chosen worker prefix,
  compares before/after snapshots, and records a `pass` / `fail`
  verdict. Snapshot-only — never drives the simulator, so it can run
  alongside a worker without contending for the device. Pure stdlib.
- [`../examples/agent/agent_canvas_to_baguette.py`](../examples/agent/agent_canvas_to_baguette.py)
  — adapter that reads an `agent-canvas/latest/manifest.json` (Expo
  Router route inventory) and emits the bulk-create envelope on
  stdout. Pipe it into `agent-sim review-tasks bulk-create --file -`
  to queue one task per route. Pure stdlib.

Copy either as a starting point for an MCP server, a CI hook, or an
autonomous-test runner. The logic is intentionally <200 LOC each so
it's straightforward to port to TypeScript / Go / your language of
choice.

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
