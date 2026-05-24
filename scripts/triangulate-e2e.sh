#!/bin/bash
# Reproducible end-to-end test for `POST /triangulate`.
#
# Exercises the LIVE HTTP path — real simulator AX hit-test + real Metro
# workspace discovery + real on-disk JSX scan + ranking — not the Domain
# unit fakes (those live in Tests/AgentSimTests/Workspace/). Re-runnable
# and deterministic given the same on-screen app state.
#
# It is SELF-CALIBRATING so it never hardcodes a fragile coordinate or a
# label that might not be present: it reads the live describe-ui tree,
# intersects the on-screen labels with the labels the scanner WOULD match
# in the discovered workspace, picks one, reads that element's frame
# (centre = tap target — never a screenshot), and triangulates there.
#
# Usage: ./scripts/triangulate-e2e.sh [--base URL] [--metro-port N]
#                                     [--udid UDID] [--label TEXT] [--no-serve]
#   --base        $SIM serve base (default: $BASE or http://127.0.0.1:8421)
#   --metro-port  Metro dev-server port to discover the workspace from (default: 8081)
#   --udid        simulator UDID (default: first Booted from `$SIM list --json`)
#   --label       force a specific on-screen label instead of auto-calibrating
#   --no-serve    don't auto-start `$SIM serve` (assume it's up)
#
# Exit: 0 = all assertions passed · 1 = an assertion failed · 2 = skipped
#       (env not ready: no booted sim / no Metro / no calibratable label).
#
# Deps: agent-sim, curl, jq, lsof (all on a standard dev box).

set -euo pipefail
cd "$(dirname "$0")/.."

BASE="${BASE:-http://127.0.0.1:8421}"
METRO_PORT="${METRO_PORT:-8081}"
UDID="${UDID:-}"
LABEL=""
SERVE=1

while [ $# -gt 0 ]; do
    case "$1" in
        --base)       BASE="$2"; shift 2 ;;
        --metro-port) METRO_PORT="$2"; shift 2 ;;
        --udid)       UDID="$2"; shift 2 ;;
        --label)      LABEL="$2"; shift 2 ;;
        --no-serve)   SERVE=0; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Resolve the CLI: prefer one on PATH (Homebrew install), else the binary
# build.sh drops at the repo root (./agent-sim). Everything below calls $SIM.
if command -v agent-sim >/dev/null 2>&1; then
    SIM="agent-sim"
elif [ -x "./agent-sim" ]; then
    SIM="./agent-sim"
else
    echo "skip: agent-sim not on PATH and ./agent-sim not built (run: make)" >&2; exit 2
fi
for dep in curl jq lsof; do
    command -v "$dep" >/dev/null 2>&1 || { echo "skip: missing dependency '$dep'" >&2; exit 2; }
done

skip() { echo "SKIP: $*" >&2; exit 2; }

PASS=0
FAIL=0
check() { # check "<description>" <condition-cmd...>
    local desc="$1"; shift
    if "$@"; then
        printf '  \033[32mPASS\033[0m %s\n' "$desc"
        PASS=$((PASS + 1))
    else
        printf '  \033[31mFAIL\033[0m %s\n' "$desc"
        FAIL=$((FAIL + 1))
    fi
}
eq()  { [ "$1" = "$2" ]; }
gt0() { [ "$1" -gt 0 ] 2>/dev/null; }

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

# Workspace root, resolved exactly the way HostMetro does: pid listening on
# the Metro port → its cwd. If Metro is down, triangulate would yield a null
# workspace and zero candidates, so this whole E2E is moot — skip cleanly.
curl -fsS --max-time 2 "http://localhost:${METRO_PORT}/status" 2>/dev/null \
    | grep -q "packager-status:running" || skip "no Metro dev-server on :$METRO_PORT"
METRO_PID="$(lsof -nP -iTCP:"$METRO_PORT" -sTCP:LISTEN -Fp 2>/dev/null | grep '^p' | head -1 | cut -c2-)"
[ -n "$METRO_PID" ] || skip "could not resolve Metro pid on :$METRO_PORT"
ROOT="$(lsof -a -p "$METRO_PID" -d cwd -Fn 2>/dev/null | grep '^n' | head -1 | cut -c2-)"
[ -n "$ROOT" ] && [ -d "$ROOT" ] || skip "could not resolve Metro workspace cwd"
echo "[e2e] udid=$UDID  base=$BASE  workspace=$ROOT" >&2

# ── Self-calibrate a target element ─────────────────────────────────────
# One describe-ui read; reused for label selection AND frame lookup.
TREE="$($SIM describe-ui --udid "$UDID" 2>/dev/null)"
[ -n "$TREE" ] && [ "$TREE" != "null" ] || skip "describe-ui returned nothing (no frontmost app?)"

pick_label() {
    # Labels on screen that the JSXScanner would match in the workspace:
    # `>X<` inline text, or `accessibilityLabel="X"`. First such label wins.
    printf '%s' "$TREE" \
        | jq -r '.. | objects | select(.label != null and .label != "") | .label' \
        | sort -u \
        | while IFS= read -r L; do
            [ -z "$L" ] && continue
            if grep -rqsF --include=\*.tsx --include=\*.jsx --include=\*.ts --include=\*.js \
                 --exclude-dir=node_modules --exclude-dir=.expo \
                 --exclude-dir=ios --exclude-dir=android \
                 -e ">$L<" -e "accessibilityLabel=\"$L\"" "$ROOT" 2>/dev/null; then
                printf '%s\n' "$L"; break
            fi
        done
}
[ -n "$LABEL" ] || LABEL="$(pick_label || true)"
[ -n "$LABEL" ] || skip "no on-screen label intersects the workspace source (nothing to triangulate)"

# Centre of the first element carrying that label (device points; same units
# as gestures). Coordinates come from the AX frame, never a screenshot.
# Extract the frame object first so a label that isn't on screen (e.g. a
# forced --label after the app navigated away) skips cleanly instead of
# dividing null in jq.
FRAME="$(printf '%s' "$TREE" | jq -c --arg L "$LABEL" \
    '[.. | objects | select(.label == $L and .frame != null)][0].frame // empty')"
[ -n "$FRAME" ] || skip "label '$LABEL' is not on screen (no frame in describe-ui)"
read -r CX CY < <(printf '%s' "$FRAME" | jq -r '"\(.x + .width/2) \(.y + .height/2)"')
[ -n "${CX:-}" ] && [ "$CX" != "null" ] || skip "no usable frame for label '$LABEL'"
# jq prints floats; /triangulate takes Double so pass them through as-is.
echo "[e2e] target label='$LABEL' centre=($CX,$CY)" >&2

# ── Exercise the live route ─────────────────────────────────────────────
printf '{"udid":"%s","x":%s,"y":%s}' "$UDID" "$CX" "$CY" > /tmp/triangulate-e2e.json
OUT="$(curl -fsS --max-time 30 -H 'content-type: application/json' \
        --data @/tmp/triangulate-e2e.json "$BASE/triangulate" 2>/dev/null)" \
    || { echo "FAIL: POST /triangulate transport error" >&2; exit 1; }

echo "$OUT" | jq . >/dev/null 2>&1 || { echo "FAIL: response is not JSON: $(printf '%s' "$OUT" | head -c 200)" >&2; exit 1; }

OK=$(echo "$OUT"      | jq -r '.ok')
NODE_LABEL=$(echo "$OUT" | jq -r '.node.label // empty')
WS_ROOT=$(echo "$OUT" | jq -r '.workspace.root // empty')
WS_FW=$(echo "$OUT"   | jq -r '.workspace.framework // empty')
NCAND=$(echo "$OUT"   | jq -r '.candidates | length')
TOP_FILE=$(echo "$OUT"| jq -r '.candidates[0].file // empty')
TOP_CONF=$(echo "$OUT"| jq -r '.candidates[0].confidence // 0')
# Ranking invariant: confidences are non-increasing across the array.
SORTED=$(echo "$OUT"  | jq -r '[.candidates[].confidence] == ([.candidates[].confidence] | sort | reverse)')
# Top candidate's file must actually contain the label (no phantom hits).
FILE_HAS_LABEL=0
[ -n "$TOP_FILE" ] && [ -f "$TOP_FILE" ] && grep -qsF "$LABEL" "$TOP_FILE" && FILE_HAS_LABEL=1

# ── Assertions ──────────────────────────────────────────────────────────
echo "── triangulate E2E: '$LABEL' → $NCAND candidate(s) ──"
check "HTTP envelope ok:true"                       eq "$OK" "true"
check "node resolved to the targeted label"         eq "$NODE_LABEL" "$LABEL"
check "workspace.root == live Metro cwd"            eq "$WS_ROOT" "$ROOT"
check "workspace.framework is expoRouter"           eq "$WS_FW" "expoRouter"
check "at least one source candidate returned"      gt0 "$NCAND"
check "top candidate is a file under the workspace" bash -c '[[ "'"$TOP_FILE"'" == "'"$ROOT"'"/* ]]'
check "top candidate confidence in (0,1]"           bash -c 'awk "BEGIN{exit !('"$TOP_CONF"'>0 && '"$TOP_CONF"'<=1)}"'
check "candidates ranked by descending confidence"  eq "$SORTED" "true"
check "top candidate file actually contains label"  eq "$FILE_HAS_LABEL" "1"

echo "──────────────────────────────────────────────"
echo "top candidate: ${TOP_FILE#$ROOT/}:$(echo "$OUT" | jq -r '.candidates[0].line'):$(echo "$OUT" | jq -r '.candidates[0].column')  conf=$TOP_CONF"
echo "result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
