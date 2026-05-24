#!/bin/bash
# Reproducible end-to-end test for the acceptance-criteria verify path
# (ADR-0002): author criteria → capture a verification snapshot → grade the
# criteria against it with `review-tasks verify-criteria`.
#
# Exercises the LIVE pipeline — real review session + real on-device capture
# (screenshot + AX artifact) + the real verdict engine reading that snapshot
# back — not the Domain unit fakes (those live in Tests/AgentSimTests/). It
# also exercises the `--live` path (a fresh describe-ui at grade time).
#
# It is SELF-CALIBRATING so it never hardcodes a fragile coordinate or label:
# it reads the live describe-ui tree, picks a real on-screen element (stable
# `identifier` preferred, else a non-empty label) as the criterion that MUST
# pass, and pairs it with a deliberately-absent identifier as the criterion
# that MUST fail — proving both the `verified` and the back-to-`open` verdicts.
#
# Usage: ./scripts/verify-criteria-e2e.sh [--base URL] [--udid UDID] [--no-serve]
#   --base       serve base (default: $BASE or http://127.0.0.1:8421)
#   --udid       simulator UDID (default: first Booted from `$SIM list --json`)
#   --no-serve   don't auto-start `$SIM serve` (assume it's up)
#
# Exit: 0 = all assertions passed · 1 = an assertion failed · 2 = skipped
#       (env not ready: no booted sim / nothing on screen to calibrate).
#
# IMPORTANT: serve and this script must share the default store
# (~/.agent-sim/reviews) — don't point serve at a custom review root, or the
# CLI verify-criteria won't find the snapshot the server captured.
#
# Deps: agent-sim, curl, jq.

set -euo pipefail
cd "$(dirname "$0")/.."

BASE="${BASE:-http://127.0.0.1:8421}"
UDID="${UDID:-}"
SERVE=1

while [ $# -gt 0 ]; do
    case "$1" in
        --base)     BASE="$2"; shift 2 ;;
        --udid)     UDID="$2"; shift 2 ;;
        --no-serve) SERVE=0; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if command -v agent-sim >/dev/null 2>&1; then
    SIM="agent-sim"
elif [ -x "./agent-sim" ]; then
    SIM="./agent-sim"
else
    echo "skip: agent-sim not on PATH and ./agent-sim not built (run: make)" >&2; exit 2
fi
for dep in curl jq; do
    command -v "$dep" >/dev/null 2>&1 || { echo "skip: missing dependency '$dep'" >&2; exit 2; }
done

skip() { echo "SKIP: $*" >&2; exit 2; }

PASS=0
FAIL=0
check() { # check "<description>" <condition-cmd...>
    local desc="$1"; shift
    if "$@"; then
        printf '  \033[32mPASS\033[0m %s\n' "$desc"; PASS=$((PASS + 1))
    else
        printf '  \033[31mFAIL\033[0m %s\n' "$desc"; FAIL=$((FAIL + 1))
    fi
}
eq() { [ "$1" = "$2" ]; }

# ── Preflight ───────────────────────────────────────────────────────────
PORT="${BASE##*:}"; PORT="${PORT%%/*}"
if [ "$SERVE" = "1" ] && ! curl -fsS --max-time 2 "$BASE/simulators" >/dev/null 2>&1; then
    echo "[e2e] starting $SIM serve on :$PORT" >&2
    $SIM serve --host 127.0.0.1 --port "$PORT" >/dev/null 2>&1 &
    SERVE_PID=$!
    trap '[ -n "${SERVE_PID:-}" ] && kill "$SERVE_PID" 2>/dev/null || true' EXIT
    for _ in $(seq 1 30); do
        curl -fsS --max-time 2 "$BASE/simulators" >/dev/null 2>&1 && break
        sleep 0.5
    done
fi
curl -fsS --max-time 2 "$BASE/simulators" >/dev/null 2>&1 || skip "$SIM serve not reachable at $BASE"

[ -n "$UDID" ] || UDID="$($SIM list --json 2>/dev/null | jq -r '.running[0].udid // empty')"
[ -n "$UDID" ] || skip "no booted simulator ($SIM list --json → running[] empty)"
echo "[e2e] udid=$UDID  base=$BASE" >&2

# ── Self-calibrate a present element ─────────────────────────────────────
TREE="$($SIM describe-ui --udid "$UDID" 2>/dev/null)"
[ -n "$TREE" ] && [ "$TREE" != "null" ] || skip "describe-ui returned nothing (no frontmost app?)"

# Prefer the first non-empty identifier (stable testID); else first non-empty
# label. Build the selector JSON + a human description for the criterion.
PRESENT_ID="$(printf '%s' "$TREE" | jq -r '[.. | objects | .identifier? // empty | select(. != "")] | .[0] // empty')"
if [ -n "$PRESENT_ID" ]; then
    PRESENT_SEL="$(jq -nc --arg v "$PRESENT_ID" '{identifier:$v}')"
    PRESENT_DESC="identifier=$PRESENT_ID exists"
else
    PRESENT_LABEL="$(printf '%s' "$TREE" | jq -r '[.. | objects | .label? // empty | select(. != "")] | .[0] // empty')"
    [ -n "$PRESENT_LABEL" ] || skip "no element with an identifier or label on screen to calibrate"
    PRESENT_SEL="$(jq -nc --arg v "$PRESENT_LABEL" '{label:$v}')"
    PRESENT_DESC="label=$PRESENT_LABEL exists"
fi
ABSENT_ID="agent-sim-e2e-absent-$RANDOM$RANDOM"
echo "[e2e] present criterion: $PRESENT_DESC  ·  absent criterion: identifier=$ABSENT_ID" >&2

# ── Build the review + two tasks carrying criteria ───────────────────────
REVIEW="$(curl -fsS --max-time 10 -XPOST "$BASE/reviews" \
    -H 'content-type: application/json' -d '{"name":"verify-criteria-e2e"}' \
    | jq -r '.id // empty')"
[ -n "$REVIEW" ] || skip "could not create a review session"

# Task PASS: only the present criterion → should grade `verified`.
TASK_PASS="$(curl -fsS --max-time 10 -XPOST "$BASE/reviews/$REVIEW/tasks" \
    -H 'content-type: application/json' -d "$(jq -nc --argjson sel "$PRESENT_SEL" --arg d "$PRESENT_DESC" \
        '{title:"present only", instructions:"e2e", snapshotIds:[],
          criteria:[{description:$d, selector:$sel, expect:{kind:"exists"}}]}')" \
    | jq -r '.id // empty')"
[ -n "$TASK_PASS" ] || skip "could not create the pass task (criteria may not have threaded)"

# Task MIXED: present + absent → should grade `open` (one pass, one fail).
TASK_MIXED="$(curl -fsS --max-time 10 -XPOST "$BASE/reviews/$REVIEW/tasks" \
    -H 'content-type: application/json' -d "$(jq -nc --argjson sel "$PRESENT_SEL" --arg d "$PRESENT_DESC" --arg a "$ABSENT_ID" \
        '{title:"present plus absent", instructions:"e2e", snapshotIds:[],
          criteria:[{description:$d, selector:$sel, expect:{kind:"exists"}},
                    {description:"absent control", selector:{identifier:$a}, expect:{kind:"exists"}}]}')" \
    | jq -r '.id // empty')"
[ -n "$TASK_MIXED" ] || skip "could not create the mixed task"

# Verify the create path actually persisted the criteria (the fix this tests).
CRIT_N="$($SIM review-tasks show "$TASK_MIXED" 2>/dev/null | jq -r '.criteria | length')"
[ "$CRIT_N" = "2" ] || skip "criteria did not persist onto the task (got ${CRIT_N:-none}, want 2)"

# ── Capture a verification snapshot and point both tasks at it ────────────
SNAP="$(curl -fsS --max-time 30 -XPOST "$BASE/reviews/$REVIEW/capture" \
    -H 'content-type: application/json' -d "$(jq -nc --arg u "$UDID" '{udid:$u}')" \
    | jq -r '.snapshot.id // empty')"
[ -n "$SNAP" ] || skip "capture returned no snapshot id"
echo "[e2e] verification snapshot=$SNAP" >&2

for T in "$TASK_PASS" "$TASK_MIXED"; do
    $SIM review-tasks result "$T" --status readyForVerify \
        --verification-snapshot-id "$SNAP" --summary "e2e ready" >/dev/null
done

# ── Grade against the captured snapshot (reproducible, simulator-free) ────
PASS_OUT="$($SIM review-tasks verify-criteria "$TASK_PASS" 2>/dev/null)"
MIXED_OUT="$($SIM review-tasks verify-criteria "$TASK_MIXED" 2>/dev/null)"

PASS_STATUS="$(echo "$PASS_OUT"  | jq -r '.status')"
PASS_V0="$(echo "$PASS_OUT"      | jq -r '.verdicts[0].outcome // empty')"
MIXED_STATUS="$(echo "$MIXED_OUT"| jq -r '.status')"
MIXED_NPASS="$(echo "$MIXED_OUT" | jq -r '[.verdicts[] | select(.outcome=="pass")] | length')"
MIXED_NFAIL="$(echo "$MIXED_OUT" | jq -r '[.verdicts[] | select(.outcome=="fail")] | length')"
# Persisted: a re-show must reflect the graded status (verdicts were stored).
PASS_PERSISTED="$($SIM review-tasks show "$TASK_PASS" 2>/dev/null | jq -r '.status')"

# ── Grade the PASS task against a fresh live capture too ──────────────────
LIVE_OUT="$($SIM review-tasks verify-criteria "$TASK_PASS" --live --udid "$UDID" 2>/dev/null || true)"
LIVE_STATUS="$(echo "$LIVE_OUT" | jq -r '.status // empty' 2>/dev/null || true)"

# ── Assertions ────────────────────────────────────────────────────────────
echo "── verify-criteria E2E ──"
check "present-only task grades verified"            eq "$PASS_STATUS" "verified"
check "present-only verdict is a pass"               eq "$PASS_V0" "pass"
check "graded status is persisted on the task"       eq "$PASS_PERSISTED" "verified"
check "mixed task grades open (a fail requeues it)"  eq "$MIXED_STATUS" "open"
check "mixed task has exactly one passing verdict"   eq "$MIXED_NPASS" "1"
check "mixed task has exactly one failing verdict"   eq "$MIXED_NFAIL" "1"
check "live grade of the present-only task verifies" eq "$LIVE_STATUS" "verified"

echo "──────────────────────────────────────────────"
echo "review=$REVIEW pass-task=$TASK_PASS mixed-task=$TASK_MIXED snapshot=$SNAP"
echo "result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
