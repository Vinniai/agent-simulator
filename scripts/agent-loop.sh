#!/bin/bash
# Bring up the agent-sim review-task queue and stream new/changed work as
# newline-delimited JSON on stdout — one line per change, dedup'd.
#
# This is the "monitor & dispatch" entry point: pipe stdout into a watcher
# (Claude Code's Monitor tool, a while-read loop, jq, …) that claims each
# task with `agent-sim review-tasks next` and spawns a worker to implement
# it. Each line is a full task-list snapshot at the moment something
# changed; downstream decides how to diff/group/dispatch.
#
# Usage: ./scripts/agent-loop.sh [--status open] [--session-id <id>]
#                                [--interval <s>] [--port 8421]
#                                [--host 0.0.0.0] [--trusted-host <h>]
#                                [--no-serve] [--once]
#   --status       filter to one task status (default: open)
#   --session-id   filter to one review session
#   --interval     poll seconds (default: 1)
#   --port         serve port to use / health-check (default: 8421)
#   --host         interface agent-sim serve binds to (default: 0.0.0.0 so
#                  the UI is reachable on the LAN IP, not just loopback;
#                  env: AGENT_SIM_HOST). agent-sim's own default is
#                  127.0.0.1, which makes http://<lan-ip>:PORT refuse.
#   --trusted-host hostname/IP allowed past agent-sim's DNS-rebind guard
#                  (env: AGENT_SIM_TRUSTED_HOST). When unset and host is
#                  0.0.0.0, the primary LAN IPv4 is auto-detected and
#                  trusted so LAN access works without extra config.
#   --no-serve     don't auto-start `agent-sim serve` (assume it's up)
#   --no-notes     don't auto-promote the session-less notes queue
#   --once         emit one snapshot and exit (no loop)
#
# Notes bridge: notes left from a simulator ("leave a note" in the UI) land
# in a SEPARATE session-less `notes` queue, not `review-tasks`. The loop only
# watches review-tasks, so without this bridge a left note is never actioned
# until someone runs `agent-sim notes promote` by hand. By default this
# script drains the existing queued-notes backlog once, then live-promotes
# every new queued note into a review-task so it flows to the loop. Disable
# with --no-notes or AGENT_SIM_NOTES_BRIDGE=0. Needs `jq` (soft-skips if
# absent — the main review-tasks loop is never affected).
#
# WebSocket alternative (server pushes, no poll loop):
#   wscat -c 'ws://127.0.0.1:8421/review-tasks/stream?status=open'
# See docs/AGENT-API.md ("Subscribing instead of polling") and
# skills/agent-sim/references/wire-protocol.md ("WS /review-tasks/stream").
#
# ⚠ Name clash: some *consumer* repos ship an unrelated `scripts/agent-sim`
# Python shim (e.g. a Convex-HTTP poller). That is NOT this CLI. This
# script resolves the real binary via `command -v agent-sim` / Homebrew.

set -euo pipefail
cd "$(dirname "$0")/.."

STATUS="open"
SESSION_ID=""
INTERVAL="1"
PORT="8421"
HOST="${AGENT_SIM_HOST:-0.0.0.0}"
TRUSTED_HOST="${AGENT_SIM_TRUSTED_HOST:-}"
SERVE=1
ONCE=0
NOTES_BRIDGE="${AGENT_SIM_NOTES_BRIDGE:-1}"

while [ $# -gt 0 ]; do
    case "$1" in
        --status)       STATUS="$2"; shift 2 ;;
        --session-id)   SESSION_ID="$2"; shift 2 ;;
        --interval)     INTERVAL="$2"; shift 2 ;;
        --port)         PORT="$2"; shift 2 ;;
        --host)         HOST="$2"; shift 2 ;;
        --trusted-host) TRUSTED_HOST="$2"; shift 2 ;;
        --no-serve)     SERVE=0; shift ;;
        --no-notes)     NOTES_BRIDGE=0; shift ;;
        --once)         ONCE=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

# When binding all interfaces and no trusted host was given, auto-detect the
# primary LAN IPv4 and trust it — otherwise agent-sim's DNS-rebind guard
# rejects requests whose Host is the LAN IP even though the socket is bound,
# so http://<lan-ip>:PORT would still fail. Mirrors worktree-metro.sh's
# Wi-Fi/default-route detection. macOS-only ipconfig; silently no-ops
# elsewhere (binds 0.0.0.0 with no auto-trust).
if [ -z "$TRUSTED_HOST" ] && { [ "$HOST" = "0.0.0.0" ] || [ "$HOST" = "::" ]; }; then
    DEF_IF="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
    TRUSTED_HOST="$(ipconfig getifaddr "${DEF_IF:-en0}" 2>/dev/null \
        || ipconfig getifaddr en1 2>/dev/null \
        || ipconfig getifaddr en0 2>/dev/null || echo '')"
fi

if ! command -v agent-sim >/dev/null 2>&1; then
    echo "error: 'agent-sim' not on PATH. Install: brew install tddworks/tap/agent-sim" >&2
    exit 1
fi

SERVE_PID=""
NOTES_PID=""
cleanup() {
    [ -n "$SERVE_PID" ] && kill "$SERVE_PID" 2>/dev/null || true
    [ -n "$NOTES_PID" ] && kill "$NOTES_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Notes→review-task bridge. Notes left from a sim land in the session-less
# `notes` queue which `review-tasks watch` never sees. Drain the existing
# queued backlog once, then live-promote every new queued note so it flows
# into the loop with no manual `agent-sim notes promote`. Best-effort: jq is
# required to pull the id out of each JSON line; if it's missing we soft-skip
# and the main review-tasks loop is entirely unaffected. The watch is wrapped
# in a reconnect loop so a dropped stream never kills the bridge.
notes_bridge() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "[agent-loop] notes bridge disabled: jq not on PATH" >&2
        return 0
    fi
    # `notes watch` prints a full queued-notes ARRAY snapshot per line (same
    # shape as `review-tasks watch`), NOT one note per line — so iterate the
    # array and promote every still-queued id. SEEN dedups across the 1-2
    # duplicate snapshots that arrive before a promote is reflected, so a note
    # is never promoted twice (which would create a duplicate review-task).
    # The herestring (`<<<`) keeps the read loop in this shell so SEEN, a
    # plain var in notes_bridge, accumulates across promote_snapshot calls.
    SEEN=""
    promote_snapshot() {
        local id ids
        ids="$(printf '%s' "$1" | jq -r '.[]? | select(.promoted != true) | .id // empty' 2>/dev/null)"
        [ -n "$ids" ] || return 0
        while IFS= read -r id; do
            [ -n "$id" ] || continue
            case " $SEEN " in *" $id "*) continue ;; esac
            SEEN="$SEEN $id"
            if agent-sim notes promote "$id" >/dev/null 2>&1; then
                echo "[agent-loop] promoted note $id → review-task" >&2
            fi
        done <<< "$ids"
    }
    # 1) Drain whatever is already queued, once.
    while IFS= read -r line; do
        [ -n "$line" ] && promote_snapshot "$line"
    done < <(agent-sim notes watch --status queued --once 2>/dev/null || true)
    # 2) Live-consume new queued notes forever; reconnect if the stream drops.
    while :; do
        while IFS= read -r line; do
            [ -n "$line" ] && promote_snapshot "$line"
        done < <(agent-sim notes watch --status queued --interval "$INTERVAL" 2>/dev/null || true)
        sleep "$INTERVAL"
    done
}

if [ "$SERVE" = "1" ]; then
    # Idempotent: only start serve if the port isn't already answering.
    if ! curl -fsS "http://127.0.0.1:${PORT}/simulators" >/dev/null 2>&1; then
        SERVE_ARGS=(serve --port "$PORT" --host "$HOST")
        [ -n "$TRUSTED_HOST" ] && SERVE_ARGS+=(--trusted-host "$TRUSTED_HOST")
        echo "[agent-loop] starting agent-sim serve on ${HOST}:${PORT}${TRUSTED_HOST:+ (trusted: $TRUSTED_HOST)}" >&2
        agent-sim "${SERVE_ARGS[@]}" >/dev/null 2>&1 &
        SERVE_PID=$!
        for _ in $(seq 1 30); do
            curl -fsS "http://127.0.0.1:${PORT}/simulators" >/dev/null 2>&1 && break
            sleep 0.5
        done
    else
        echo "[agent-loop] reusing serve already on :${PORT}" >&2
    fi
fi

# Bridge runs alongside the loop. Skip it for --once (one snapshot, no daemon)
# and when explicitly disabled with --no-notes / AGENT_SIM_NOTES_BRIDGE=0.
if [ "$NOTES_BRIDGE" = "1" ] && [ "$ONCE" != "1" ]; then
    notes_bridge &
    NOTES_PID=$!
    echo "[agent-loop] notes bridge live (queued notes auto-promote → review-tasks)" >&2
fi

WATCH=(review-tasks watch --interval "$INTERVAL")
[ -n "$STATUS" ]     && WATCH+=(--status "$STATUS")
[ -n "$SESSION_ID" ] && WATCH+=(--session-id "$SESSION_ID")
[ "$ONCE" = "1" ]    && WATCH+=(--once)

echo "[agent-loop] watching: agent-sim ${WATCH[*]}" >&2
# `exec` would replace the shell and orphan the bridge + skip the cleanup
# trap, so when the bridge is live we run the watch as a child and forward
# its exit. With no bridge, exec is fine (nothing to clean up but serve).
if [ -n "$NOTES_PID" ]; then
    agent-sim "${WATCH[@]}"
else
    exec agent-sim "${WATCH[@]}"
fi
