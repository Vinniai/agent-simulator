# Prompt: implement → verify-on-sim → self-queue defects → iterate

Paste this into a Claude Code session running in your **Expo app repo**
(the app whose features you're building — e.g. `taskr-convex-test/apps/mobile`),
with `agent-sim serve` reachable at `$BASE`. Fill the four placeholders at the top.

---

You are implementing a feature in this Expo Router app and proving it works on a
real iOS simulator. agent-sim is your eyes (AX tree / screenshot / source
triangulation), hands (tap / type / gesture), and defect ledger (the review-task
queue). Drive a closed loop: **code → reload → verify on the sim → on any failed
check, file a defect into the agent-sim queue with its triangulated source
location → claim it → fix → re-verify.** Do not stop until every acceptance
criterion passes on a fresh verification AND the queue has no open tasks.

## Inputs
- FEATURE: <one-paragraph description of the feature to build>
- ACCEPTANCE CRITERIA (each must be verifiable on-screen):
  1. <e.g. "Tapping the + FAB on the Tasks tab opens a Create Task sheet">
  2. <e.g. "The sheet has a title field labelled 'Task name' and a Save button">
  3. <e.g. "Saving with an empty name shows an inline 'Name required' error">
- UDID: <booted simulator UDID, from `agent-sim list --json`>
- BASE: http://127.0.0.1:8421   (agent-sim serve)
- W, H: <device-point width,height from `agent-sim list --json | jq '.running[0].screen'`>

## Tools you will use
- `agent-sim describe-ui --udid $UDID` → AX tree. Use it to ASSERT elements exist
  with expected labels/roles, and to read element frames (centers = tap targets).
  NEVER derive tap coordinates from a screenshot — always from describe-ui.
- `agent-sim tap|double-tap|swipe ... --udid $UDID --x .. --y .. --width $W --height $H`
  → exercise the UI. Coordinates are device points (same units as the frames).
- `agent-sim screenshot --udid $UDID -o /tmp/step.png` → visual confirmation; read it.
- `POST $BASE/triangulate {udid,x,y}` → map a misbehaving element's tap-center to the
  source file:line that rendered it (`candidates[0]` is the best guess). This is how a
  defect gets an actionable source pointer.
- Queue (your defect ledger):
  - File a defect: `agent-sim notes add --udid $UDID --text "<defect>" --source <file:line:col>`
    (the running `agent-loop.sh` auto-promotes queued notes → review-tasks).
  - Or file structured work directly: `agent-sim review-tasks bulk-create` from a JSON file.
  - Claim next: `agent-sim review-tasks next` → returns one task or nothing.
  - Record the fix: `agent-sim review-tasks add-code-change <task-id> ...` then
    `agent-sim review-tasks result <task-id> --status verified` (or `failed` to requeue).
  - Check the board: `agent-sim review-tasks list --status open`.

## The loop (repeat until the exit condition)
1. **Code.** Implement the smallest slice toward the next unmet criterion. Edit the
   app's `.tsx`/`.ts` source. Keep changes minimal and idiomatic to the surrounding code.
2. **Reload.** Save — Metro fast-refresh reloads the app. If the screen doesn't update
   within a few seconds, trigger a reload (Metro `r`, or relaunch the app).
3. **Verify on the sim.** For each acceptance criterion:
   - `describe-ui` and assert the expected element exists (right label, role, enabled).
   - Drive the interaction with `tap`/`double-tap`/`swipe` using frames from describe-ui.
   - `describe-ui` again and/or `screenshot` to confirm the post-state.
4. **Judge.** A criterion PASSES only if the AX assertion + the post-state both hold.
   If the app shows a redbox / render error, that's an automatic FAIL.
5. **On any FAIL — file a defect (don't just retry):**
   - Get the source pointer: `POST $BASE/triangulate {udid, x, y}` at the offending
     element's center. Take `candidates[0]` → `<file:line:col>`.
   - `agent-sim notes add --udid $UDID --text "FAIL <criterion>: <what you observed vs expected>" --source <file:line:col>`
   - This becomes a review-task via the notes bridge — your durable to-do for this defect.
6. **Drain the queue.** `agent-sim review-tasks next`; for each claimed task, fix the
   code at the named source pointer, reload, re-verify that specific criterion, then
   `review-tasks result <id> --status verified`. If still broken, `--status failed`
   with a note and loop.
7. **Re-verify everything** once the queue is empty (a late fix can regress an earlier
   criterion).

## Exit condition (state it explicitly when you stop)
Stop ONLY when, in a single fresh pass: every acceptance criterion verifies on the sim
AND `agent-sim review-tasks list --status open` is empty. Report: which criteria you
verified, the final screenshot path per criterion, and the commits/files changed.

## Rules
- One criterion at a time; smallest code change that could satisfy it.
- Every tap target comes from a describe-ui frame, never from a screenshot.
- Every filed defect carries a triangulated `--source` so the fix is unambiguous.
- Never declare done on a screen showing a redbox or with open tasks in the queue.
- If you get stuck on the same criterion twice, file the defect, write down the two
  hypotheses you've ruled out in the note, and try a different approach — don't spin.
```

## Worked example (taskr "Create Task" flow)
FEATURE: Add a Create-Task sheet reachable from the Tasks tab FAB.
ACCEPTANCE:
  1. Tasks tab shows a round + FAB bottom-right.
  2. Tapping it opens a sheet titled "New Task".
  3. The sheet has a "Task name" text field and a "Save" button.
  4. Save with empty name → inline "Name required" error, sheet stays open.
UDID: 68DA7548-1D70-4AB1-B981-A048F1356F23   BASE: http://127.0.0.1:8421   W,H: 440,956
```
