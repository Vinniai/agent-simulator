# `agent-simulator` CLI reference

All commands print JSON when there's structured data to return; one-shots
return `{"ok":true}` / `{"ok":false,"error":"…"}`. Errors go to stderr.

## Discovery — `list`

```bash
agent-simulator list                  # human table (Booted ●  iPhone 17 Pro Max  iOS 26.4  <UDID>)
agent-simulator list --json           # {"running":[…], "available":[…]}
```

Each device entry: `{ id, name, state, runtime, isBooted }`. Use `id`
(the UDID) for every other command. `state` is "Booted" or "Shutdown".

To pick the first running iPhone:

```bash
agent-simulator list --json \
  | jq -r '.running[] | select(.name | startswith("iPhone")) | .id' \
  | head -1
```

## Lifecycle — `boot` / `shutdown`

```bash
agent-simulator boot     --udid <UDID>
agent-simulator shutdown --udid <UDID>
```

Headless boot — the CoreSimulator framework spins the device up without
opening Simulator.app. `boot` is idempotent: an already-booted device
returns `{"ok":true}`.

## Screen geometry — `chrome layout`

```bash
agent-simulator chrome layout --udid <UDID>           # JSON
agent-simulator chrome layout --device-name "iPhone 17 Pro Max"
```

Returns:

```json
{
  "composite": {"width": 552, "height": 1115},
  "screen":    {"width": 438, "height": 954, "x": 57, "y": 81},
  "innerCornerRadius": 55,
  "buttons": [...]
}
```

The `screen.width` / `screen.height` are the values you pass as `width` /
`height` on every gesture. `composite` is the bezel image dimensions.

## One-shot gestures

Same wire format as `agent-simulator input`, one gesture per process. Use these
in shell scripts where you don't need streaming throughput.

```bash
agent-simulator tap   --udid X --x 219 --y 478 --width 438 --height 954 [--duration 0.05]
agent-simulator swipe --udid X --startX 219 --startY 760 --endX 219 --endY 190 \
                       --width 438 --height 954 [--duration 0.3]
agent-simulator pinch --udid X --cx 219 --cy 478 --startSpread 60 --endSpread 240 \
                       --width 438 --height 954 [--duration 0.6]
agent-simulator pan   --udid X --x1 175 --y1 478 --x2 263 --y2 478 \
                       --dx 0 --dy 200 --width 438 --height 954 [--duration 0.5]
agent-simulator press --udid X --button home              # home | lock | power | volume-up | volume-down | action | app-switcher | swipe-to-app-switcher | swipe-to-home | pull-down-to-lock-screen | pull-down-to-notification-center
agent-simulator press --udid X --button action --duration 1.2   # long-press → "Hold for Ring"
agent-simulator press --udid X --button app-switcher                        # double home-press recipe → multitasking cards
agent-simulator press --udid X --button swipe-to-app-switcher               # slow drag-and-hold from the bottom edge → cards (gesture path)
agent-simulator press --udid X --button swipe-to-home                       # streamed home-indicator gesture
agent-simulator press --udid X --button pull-down-to-lock-screen            # slow drag from top-left → lock-screen cover sheet
agent-simulator press --udid X --button pull-down-to-notification-center    # slow drag from top-right → Notification Center
agent-simulator key   --udid X --code KeyA --modifiers shift,command [--duration 0.2]
agent-simulator type  --udid X --text "hello world"
```

`x` / `y` etc. are device points (see `wire-protocol.md` for the
coordinate convention). `width` / `height` come from `chrome layout`.

### Hardware buttons — `press`

```bash
agent-simulator press --udid X --button home                       # short tap
agent-simulator press --udid X --button power --duration 2.5       # Siri / SOS hold
agent-simulator press --udid X --button volume-up
```

| Button           | iOS effect                  | Long-hold (≥ ~0.8 s)              |
|------------------|-----------------------------|-----------------------------------|
| `home`           | Home / app switcher         | n/a                               |
| `lock`           | Sleep / wake                | n/a                               |
| `power`          | Sleep / wake                | Siri (~1.5 s) / SOS slider (~5 s) |
| `volume-up`      | Volume up                   | Accessibility shortcut            |
| `volume-down`    | Volume down                 | Accessibility shortcut            |
| `action`         | iPhone 15 Pro action button | "Hold for Ring" / silent flip     |
| `app-switcher`   | Two consecutive home presses → multitasking cards | n/a (canned shape) |
| `swipe-to-app-switcher` | Slow drag-and-hold from bottom edge → multitasking cards (gesture path) | n/a (canned shape) |
| `swipe-to-home`  | Swipe up from bottom edge → home | n/a (canned shape)           |
| `pull-down-to-lock-screen` | Slow drag down from top-left → lock-screen cover sheet | n/a (canned shape) |
| `pull-down-to-notification-center` | Slow drag down from top-right → Notification Center | n/a (canned shape) |

`--duration <seconds>` is optional (default ~100 ms). `siri` is
explicitly rejected — it crashes `backboardd` through every known
Indigo path. `app-switcher`, `swipe-to-app-switcher`, `swipe-to-home`,
`pull-down-to-lock-screen`, and `pull-down-to-notification-center`
are *virtual* buttons — no physical counterpart, but they're useful
when the agent wants the gesture vocabulary without managing a
streaming touch chain manually. See
[`docs/features/buttons.md`](../../../docs/features/buttons.md) and
[`docs/features/touches.md`](../../../docs/features/touches.md) for
the dispatch path.

### Keyboard — `key` / `type`

```bash
# Single keystroke. `--code` is a W3C KeyboardEvent.code.
agent-simulator key --udid X --code KeyA                          # types 'a'
agent-simulator key --udid X --code KeyA --modifiers shift        # 'A'
agent-simulator key --udid X --code KeyA --modifiers shift,command --duration 0.2

# Multi-character text (US ASCII only).
agent-simulator type --udid X --text "hello world"
agent-simulator type --udid X --text "Login: alice@example.com"
```

Supported codes: `KeyA`–`KeyZ`, `Digit0`–`Digit9`, `Enter`, `Escape`,
`Backspace`, `Tab`, `Space`, `ArrowUp/Down/Left/Right`, US punctuation
(`Minus`, `Equal`, `BracketLeft`, …). Modifiers: `shift`, `control`,
`option`, `command` (comma-separated on the CLI). Phase-1 limits:
**no IME, no emoji, no accented characters** — those need
`KeyboardNSEvent` (phase 2). See
[`docs/features/keyboard.md`](../../../docs/features/keyboard.md).

## Streaming gestures — `input`

```bash
agent-simulator input --udid <UDID>                # reads stdin, writes acks per line
```

Use for sequences. Reading stops on EOF. Pair with `tee` for logging:

```bash
{ echo '{"type":"button","button":"home"}'
  echo '{"type":"tap","x":219,"y":478,"width":438,"height":954}'
} | agent-simulator input --udid X | tee /tmp/agent-simulator-acks.log
```

## One-shot screenshot — `screenshot`

```bash
agent-simulator screenshot --udid <UDID>                              # → JPEG on stdout
agent-simulator screenshot --udid <UDID> --output /tmp/shot.jpg
agent-simulator screenshot --udid <UDID> --quality 0.6 --scale 2 > thumb.jpg
```

| Flag       | Default | Effect                                                       |
|------------|---------|--------------------------------------------------------------|
| `--output` | stdout  | Write JPEG bytes to a file instead of stdout (CLI only).     |
| `--quality`| `0.85`  | JPEG lossy compression (0.0 – 1.0).                          |
| `--scale`  | `1`     | Integer downscale divisor: 1 = native, 2 = half, 3 = third.  |

Equivalent HTTP route during `agent-simulator serve`:

```
GET http://localhost:8421/simulators/<UDID>/screenshot.jpg[?quality=0.6][?scale=2]
```

Same defaults, same bytes — the route and the CLI share `ScreenSnapshot.capture`.

**Failure modes:**
- **2 s timeout / `Failure.timeout`.** SimulatorKit only emits a frame
  on a screen change. A booted-but-idle simulator (lock screen with no
  visible clock tick, headless test runner waiting on input) may never
  produce a frame. Wake the screen with a gesture before capturing:
  ```bash
  agent-simulator tap --udid X --x 1 --y 1 --width "$W" --height "$H"
  sleep 0.2
  agent-simulator screenshot --udid X --output /tmp/shot.jpg
  ```
- **Unknown UDID.** HTTP returns `404 application/json {"ok":false,"error":"unknown udid: <udid>"}`;
  CLI exits non-zero with the same message on stderr.

**Limits:** JPEG only (no PNG / WebP / AVIF yet); raw framebuffer (no
bezel composite — that's a browser-side concern via `bezel.png`).

## Accessibility tree — `describe-ui`

```bash
agent-simulator describe-ui --udid <UDID>                                   # full frontmost-app tree, JSON to stdout
agent-simulator describe-ui --udid <UDID> --x 172 --y 880                   # hit-test: topmost AX node at (172, 880)
agent-simulator describe-ui --udid <UDID> --output /tmp/tree.json
```

Returns one JSON object (the root `AXNode`) per call:

```json
{
  "role": "AXButton",
  "subrole": null,
  "label": "Safari",
  "value": null,
  "identifier": "Safari",
  "title": null,
  "help": "Double tap to open",
  "frame": { "x": 136, "y": 844.33, "width": 72, "height": 72 },
  "enabled": true, "focused": false, "hidden": false,
  "children": []
}
```

`frame` is in **device points** — same units as `tap` / `swipe`
wire fields (`x`, `y`, `width`, `height`). An agent that wants to
"tap the Safari button" reads `frame.x + frame.width/2`,
`frame.y + frame.height/2` straight back into a `tap` envelope.

| Flag       | Default | Effect                                                       |
|------------|---------|--------------------------------------------------------------|
| `--x`      | unset   | Hit-test x coordinate (device points). Pair with `--y`.      |
| `--y`      | unset   | Hit-test y coordinate (device points). Pair with `--x`.      |
| `--output` | stdout  | Write the JSON to a file instead of stdout.                  |

Both `--x` and `--y` must be given together; either alone errors.

**Failure modes:**
- **`no accessibility data`** — simulator not booted, or the
  frontmost slot is empty (e.g. lock screen with nothing focused).
  Exits non-zero. Wake the screen with a gesture or boot the sim.
- **Framework load failure.** `agent-simulator` logs `[ax]` lines on
  stderr; the CLI exits non-zero. Most common cause is running on
  an Xcode older than 26 — the dispatcher recipe targets iOS 26+.

## Live unified log — `logs`

```bash
agent-simulator logs --udid <UDID>                                 # info-and-above, line-buffered to stdout
agent-simulator logs --udid <UDID> --level debug                   # everything including debug-level chatter
agent-simulator logs --udid <UDID> --style json                    # one JSON object per line
agent-simulator logs --udid <UDID> --bundle-id com.apple.MobileSafari
agent-simulator logs --udid <UDID> --predicate 'subsystem == "com.apple.UIKit"'
agent-simulator logs --udid <UDID> | grep -i error                 # composes with shell pipelines; SIGINT to stop
```

| Flag           | Default   | Effect                                                            |
|----------------|-----------|-------------------------------------------------------------------|
| `--level`      | `info`    | `default` \| `info` \| `debug`. iOS-runtime `log stream` accepts only these three; **not** `notice / error / fault`. |
| `--style`      | `default` | `default` \| `compact` \| `json` \| `ndjson` \| `syslog`.         |
| `--predicate`  | unset     | Raw `NSPredicate` passed to `log stream --predicate` verbatim.    |
| `--bundle-id`  | unset     | Shorthand → `process == "<id>"`. ANDs with `--predicate` when both given. |

Equivalent WebSocket route during `agent-simulator serve`:

```
WS  /simulators/<UDID>/logs?level=info&style=default[&predicate=…&bundleId=…]
→ {"type":"log_started"}
→ {"type":"log","line":"<entry>"}
→ {"type":"log_stopped","reason":"…"}
```

Filter is fixed at connect time — restart the socket to change it. Send `{"type":"stop"}` to terminate early.

**Failure modes:**
- **`logs: invalid --level '<x>'`** — the simulator's `log` binary only accepts `default | info | debug`. Map `error` / `fault` requirements onto a predicate (`messageType == 'error'`).
- **Spawn failure.** Surfaced on stderr as `logs: <error>`. Most common: simulator not booted.
- **Slow consumer (WS only).** Buffered to 2048 lines per socket; older lines drop silently if the client falls behind.

## Live frame stream — `stream`

```bash
agent-simulator stream --udid <UDID> --format mjpeg --fps 60
agent-simulator stream --udid <UDID> --format avcc  --fps 60      # H.264 NAL units
```

Writes the live encoded stream to stdout. Pipe to `ffplay` or a
recording sink. For a single still image use `agent-simulator screenshot`
above — it has no encoder warm-up cost and respects a clean 2 s
timeout. `stream | head -c …` is *not* the snapshot path; the live
stream pipeline interferes with concurrent gestures.

## Standalone web UI — `serve` (for humans, not agents)

```bash
agent-simulator serve [--host 127.0.0.1] [--port 8421]
# → http://localhost:8421/simulators            (device list)
# → http://localhost:8421/simulators/<UDID>     (focus mode — 1 sim, fullscreen)
# → http://localhost:8421/farm                  (multi-device dashboard)
```

Agents typically don't need this — `agent-simulator input` is the programmatic
path. Mention it once if a human asks how to interact with the sim
themselves while you work.

## Bezel rasterisation — `chrome composite`

```bash
agent-simulator chrome composite --udid <UDID>            > bezel.png
agent-simulator chrome composite --device-name "iPhone 17 Pro Max" > bezel.png
```

Returns the device chrome (rounded glass + buttons) as a PNG, suitable
for compositing under a captured screenshot.

## Review-task queue — `review-tasks` / `agent`

The autonomous loop surface: a queue of UI-review / fix work items
backed by `SQLiteReviewTaskStore` (shared by the CLI *and* the HTTP/WS
routes — mixed operator-CLI + agent-HTTP is fine). Full protocol with
HTTP equivalents and reference Python agents: `docs/AGENT-API.md`.

### Poll for new work — `review-tasks watch`

```bash
agent-simulator review-tasks watch                       # all tasks, 1s interval
agent-simulator review-tasks watch --status open         # only open work
agent-simulator review-tasks watch --session-id <id> --interval 2
agent-simulator review-tasks watch --status open --once  # one snapshot, then exit
```

Blocks and prints **one compact JSON line per change** (state is
dedup'd — an unchanged poll prints nothing), `fflush`'d so it pipes
cleanly into a watcher/dispatcher. `--once` prints a single snapshot
and exits (good for cron / a one-shot check).

| Flag           | Default | Effect                                            |
|----------------|---------|---------------------------------------------------|
| `--status`     | unset   | Filter to one task status (`open`, `claimed`, …). |
| `--session-id` | unset   | Filter to one review session.                     |
| `--interval`   | `1`     | Poll seconds; must be `> 0`.                      |
| `--once`       | off     | Emit one snapshot and exit (no loop).             |

Websocket alternative (server pushes, no poll loop) during
`agent-simulator serve` — see `wire-protocol.md` → "WS /review-tasks/stream".

### Claim / progress / submit — the loop

```bash
agent-simulator review-tasks list   [--session-id <id>] [--status <s>]
agent-simulator review-tasks next   --agent-id <id>              # atomic claim → JSON task | null
agent-simulator review-tasks claim  <task-id> --agent-id <id>    # claim a specific task
agent-simulator review-tasks show   <task-id>
agent-simulator review-tasks event  <task-id> --type progress --actor <id> --message "…"   # '-' = stdin
agent-simulator review-tasks add-code-change <task-id> --path /abs/File.swift \
        --summary "…" --start-line 42 --end-line 58 \
        --commit-sha "$(git rev-parse HEAD)" --branch "$(git branch --show-current)" \
        --language swift --diff-file /tmp/x.diff --actor <id>
agent-simulator review-tasks add-code-change <task-id> --changes-file changes.json   # batch form
agent-simulator review-tasks result <task-id> --status readyForVerify --summary "…" \
        --verification-snapshot-id snap_… --actor <id>     # '-' = stdin on --summary
agent-simulator review-tasks result <task-id> --verification-snapshot-id snap_… \
        --summary "ready" --auto-verify                    # record + grade in one call (opt-in)
agent-simulator review-tasks verify <task-id> --status pass --after-snapshot-id snap_… [--notes -]
agent-simulator review-tasks verify-criteria <task-id>                    # grade criteria vs the task's snapshot
agent-simulator review-tasks verify-criteria <task-id> --live --udid <id> # grade vs a fresh describe-ui capture
agent-simulator review-tasks criterion --udid <id> --x 120 --y 640        # author a criterion from the live element there
agent-simulator review-tasks bulk-create --session-id <id> --file tasks.json \
        [--assignee <id>] [--priority high] [--title …] [--instructions …]
agent-simulator review-tasks bulk-create --session-id <id> --file -        # envelope on stdin
```

- `next` / `claim` accept **`--actor` as an alias for `--agent-id`**, so
  one identity flag works across every subcommand. The claim is
  **atomic** against SQLite — concurrent pollers are safe; exactly one
  agent gets any given task (`open → claimed`, `assignee` set).
- `--message` / `--summary` / `--notes` accept `-` to read stdin.
- `bulk-create` takes either a full `ReviewTaskBulkCreateInput` envelope
  or a bare item array; CLI `--assignee/--priority/--title/--instructions`
  override file-level `defaults` (re-tag a batch without rewriting JSON).
  Returns a partial-success envelope: `created.count + errors.count == tasks.count`.
- `verify-criteria` is the **authoritative grader** (ADR-0002): it runs a task's
  acceptance criteria through the verdict engine and drives `status` to
  `verified` (all pass) or back to `open` (any fail/ambiguous), persisting the
  `verdicts[]`. Default reads the task's verification snapshot (reproducible, no
  simulator); `--live --udid` grades a fresh `describe-ui`. Author criteria at
  task-creation time (`criteria[]` on `POST /reviews/:id/tasks`).
- `criterion` hit-tests the live tree at a device-point coordinate (tap-target
  convention) and prints an `exists` criterion keyed on the element's
  `identifier` (else `label`) — paste it into a task's `criteria[]` instead of
  hand-writing the selector.
- `result --auto-verify` (or `?verify=1` on the `/review-tasks/:id/status` /
  `/agent/tasks/:id/result` routes) records the result **and** grades the
  criteria against the attached snapshot in one call — opt-in, because a
  wrong-screen snapshot would auto-fail a task. A fail just returns it to `open`.

### Session + gate — `agent`

```bash
agent-simulator agent bootstrap [--name …] [--project <path>] [--bundle-id <id>] \
                          [--agent-id agent-simulator] [--json]   # → session + 3 starter tasks
agent-simulator agent status   [--session-id <id>] [--json]       # session/task rollup
agent-simulator agent quality-gate <task-id> --score 8 \
                          [--highest-recommendation none] [--after-snapshot-id snap_…] \
                          [--actor agent-simulator]                # pass iff score≥8 & no high/critical/p0/p1
```

`bootstrap` prints the review URL `http://127.0.0.1:8421/reviews/<id>`
and the created task ids; pair with `serve` to drive the loop.

## Session-less notes queue — `notes`

The "drop a message from the phone" queue. A note is a one-off
message (optionally anchored to an AX element + a source file:line)
stored in `~/Library/Application Support/agent-simulator/notes.sqlite`.
Same store the `serve` mobile screen writes to — a note left on a
phone is visible here within one poll, and vice versa.

```bash
agent-simulator notes list  [--status queued|promoted|all]
agent-simulator notes add   --udid <UDID> --text "…" [--ax-path <p>] [--source <file:line[:col]>]
agent-simulator notes promote <note-id>           # flip to picked-up + file as a review task
agent-simulator notes watch [--status …] [--interval 1] [--once] [--webhook URL]
agent-simulator notes watch --stream ws://127.0.0.1:8421/notes/stream
```

- `--text -` reads the message from stdin.
- `--source` parses `file:line[:col]` into a one-candidate source
  envelope (`confidence: 1.0`). Same shape as the browser attaches
  via `/triangulate`, so an agent that already has a file pointer
  (stack trace, lint hit, blame line) doesn't need AX coordinates
  to anchor a note: `notes add --udid X --text "fix copy" --source app/index.tsx:42:9`.
- Every returned JSON object carries the full `source` field — see
  `wire-protocol.md` → "Session-less notes queue" for the shape.
- `watch --stream` consumes `WS /notes/stream` live; the in-process
  `NotesStreamFrame` decoder filters out lifecycle frames so output
  matches poll mode exactly. `--webhook` POSTs each changed snapshot.
- `promote` flips the note and, in the same shot, files a one-task
  bulk-create into the shared `notes` review backlog (see
  `review-tasks` below).

## Exit codes

`0` on success. `1` on any error; the JSON error body explains. Errors
that come from SimulatorHID (wrong UDID, device not booted, malformed
gesture) return `{"ok":false,"error":"…"}` and exit `1` — parse stdout,
not just the exit code.