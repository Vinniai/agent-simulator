# Prompt: implement → verify-on-sim → self-queue defects → iterate

Paste this into a Claude Code session running in your **Expo app repo**
(the app whose features you're building — e.g. `taskr-convex-test/apps/mobile`),
with `agent-sim serve` reachable at `$BASE`. Fill the placeholders at the top.

---

You are implementing a feature in this Expo Router app and proving it works on a
real iOS simulator. agent-sim is your eyes (AX tree / screenshot / source
triangulation), hands (tap / type / gesture), and defect ledger (the review-task
queue). Drive a closed loop: **author machine-checkable acceptance criteria →
code → reload → capture a verification snapshot → let agent-sim grade the
criteria against it → on any FAIL, file a defect with its triangulated source
location → claim it → fix → re-verify.** The grade is authoritative: a task is
`verified` only when *every* criterion passes; any fail sends it back to `open`.
Do not stop until every task is `verified` and the queue has no open tasks.

## Inputs
- FEATURE: <one-paragraph description of the feature to build>
- ACCEPTANCE CRITERIA — express each as a structured, machine-checkable criterion
  (see "Authoring criteria" below). Prefer a stable `identifier` (the element's
  `accessibilityIdentifier` / React Native `testID`) over a visible label.
- UDID: <booted simulator UDID, from `agent-sim list --json`>
- BASE: http://127.0.0.1:8421   (agent-sim serve)
- W, H: <device-point width,height from `agent-sim list --json | jq '.running[0].screen'`>

## Authoring criteria (the contract agent-sim will grade)
A criterion is an **element selector** + an **expected state**. Whatever selector
fields you set are ANDed; an all-empty selector matches nothing on purpose.
Expected states are `kind`-tagged:

| expected state                        | passes when …                                    |
|---------------------------------------|--------------------------------------------------|
| `{"kind":"exists"}`                   | exactly one element matches the selector         |
| `{"kind":"absent"}`                   | no element matches                               |
| `{"kind":"enabled"}` / `disabled`     | the single match is enabled / disabled           |
| `{"kind":"textEquals","text":"…"}`    | the single match's label/value equals `text`     |
| `{"kind":"textContains","text":"…"}`  | the single match's label/value contains `text`   |

`enabled`/`disabled`/`text…` are **ambiguous** (a non-pass) unless the selector
resolves to exactly one element — tighten the selector with an `identifier`.

Create the review and a task that *carries its criteria* up front:

```bash
# 1. open a review session to hang work off of
REVIEW=$(curl -fsS -XPOST "$BASE/reviews" -H 'content-type: application/json' \
  -d '{"name":"create-task-sheet"}' | jq -r '.id')

# 2. create a task whose acceptance criteria agent-sim will grade
TASK=$(curl -fsS -XPOST "$BASE/reviews/$REVIEW/tasks" -H 'content-type: application/json' -d '{
  "title": "Create-Task sheet",
  "instructions": "Add a Create-Task sheet reachable from the Tasks tab FAB.",
  "priority": "high",
  "snapshotIds": [],
  "criteria": [
    {"description":"+ FAB present on Tasks tab",
     "selector":{"identifier":"tasks-fab"}, "expect":{"kind":"exists"}},
    {"description":"sheet titled New Task",
     "selector":{"identifier":"create-sheet-title"}, "expect":{"kind":"textEquals","text":"New Task"}},
    {"description":"Save disabled until a name is typed",
     "selector":{"identifier":"create-save"}, "expect":{"kind":"disabled"}},
    {"description":"empty-name error shows",
     "selector":{"identifier":"name-error"}, "expect":{"kind":"textContains","text":"required"}}
  ]
}' | jq -r '.id')
```

## Tools you will use
- `agent-sim describe-ui --udid $UDID` → AX tree. Read it to find the element
  frames you need to drive interactions (centre = tap target). NEVER derive tap
  coordinates from a screenshot — always from describe-ui.
- `agent-sim tap|double-tap|swipe ... --udid $UDID --x .. --y .. --width $W --height $H`
  → exercise the UI. Coordinates are device points (same units as the frames).
- `agent-sim screenshot --udid $UDID -o /tmp/step.png` → visual confirmation; read it.
- `POST $BASE/triangulate {udid,x,y}` → map a misbehaving element's tap-center to the
  source file:line that rendered it (`candidates[0]` is the best guess). This is how a
  defect gets an actionable source pointer.
- **Verification (the authoritative grader):**
  - Capture the screen as a verification snapshot:
    `SNAP=$(curl -fsS -XPOST "$BASE/reviews/$REVIEW/capture" -H 'content-type: application/json' -d "{\"udid\":\"$UDID\"}" | jq -r '.snapshot.id')`
  - Point the task at it: `agent-sim review-tasks result $TASK --status readyForVerify --verification-snapshot-id $SNAP --summary "ready"`
  - Grade the criteria against that snapshot (no simulator needed — reproducible):
    `agent-sim review-tasks verify-criteria $TASK` → prints the task with `verdicts[]`
    and `status` set to `verified` (all pass) or `open` (any fail/ambiguous).
  - Or grade a *live* capture instead of the snapshot:
    `agent-sim review-tasks verify-criteria $TASK --live --udid $UDID`.
- Queue (your defect ledger):
  - Claim next: `agent-sim review-tasks next --actor <agent-id>` → one task or nothing.
  - Record a fix: `agent-sim review-tasks add-code-change $TASK --path <file> --start-line N ...`.
  - Check the board: `agent-sim review-tasks list --status open`.

## The loop (repeat until the exit condition)
1. **Code.** Implement the smallest slice toward the next failing criterion. Edit the
   app's `.tsx`/`.ts` source. Give every asserted element a stable `testID` that
   matches the criterion's `identifier`. Keep changes minimal and idiomatic.
2. **Reload.** Save — Metro fast-refresh reloads the app. If the screen doesn't update
   within a few seconds, trigger a reload (Metro `r`, or relaunch the app).
3. **Drive to the state under test.** Use `describe-ui` frames to tap/type/swipe the app
   into the screen a criterion is about (e.g. open the sheet, submit the empty form).
4. **Capture + grade.** Capture a verification snapshot, point the task at it, and run
   `review-tasks verify-criteria $TASK`. Read the returned `verdicts[]`. **The status it
   sets is the verdict — don't second-guess a `verified`, don't argue with an `open`.**
5. **On `open` — file a defect per failing verdict (don't just retry):**
   - For each `verdicts[] where outcome != "pass"`, find the offending element and get a
     source pointer: `POST $BASE/triangulate {udid, x, y}` at its centre →
     `candidates[0]` → `<file:line:col>`.
   - `agent-sim review-tasks event $TASK --type defect --message "FAIL <criterion.description>: <reason from verdict>" --metadata-json '{"file":"<file:line:col>"}'`
   - Fix the code at that pointer, record it with `add-code-change`, then go back to 2.
6. **Re-grade everything** once you believe it's fixed — a late fix can regress an earlier
   criterion. The task only counts as done when `verify-criteria` returns `verified`.

## Exit condition (state it explicitly when you stop)
Stop ONLY when, in a single fresh pass: `review-tasks verify-criteria` returns
`verified` for every task AND `agent-sim review-tasks list --status open` is empty.
Report: each task's final `verdicts[]`, the verification snapshot id per task, the
final screenshot path, and the commits/files changed.

## Rules
- Author criteria as structured selector+expect — they are the contract agent-sim grades,
  not prose you eyeball.
- One criterion at a time; smallest code change that could satisfy it; stable `testID`s.
- Every tap target comes from a describe-ui frame, never from a screenshot.
- The `verify-criteria` verdict is authoritative — never hand-wave a task to `verified`.
- Every filed defect carries the failing verdict's reason and a triangulated source pointer.
- Never declare done with any task not `verified` or any open task in the queue.
- If the same criterion fails twice, write the two hypotheses you've ruled out into the
  defect event and try a different approach — don't spin.

## Worked example (taskr "Create Task" flow)
FEATURE: Add a Create-Task sheet reachable from the Tasks tab FAB.
CRITERIA (testIDs in parens are what the app must set):
  1. `tasks-fab` exists (round + FAB bottom-right on the Tasks tab).
  2. `create-sheet-title` textEquals "New Task" (sheet opened by the FAB).
  3. `create-save` disabled until a name is typed.
  4. `name-error` textContains "required" after Save with an empty name.
UDID: 68DA7548-1D70-4AB1-B981-A048F1356F23   BASE: http://127.0.0.1:8421   W,H: 440,956
