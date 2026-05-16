#!/bin/bash
# List upstream (tddworks/baguette) commits not yet absorbed into this fork.
#
# This fork has diverged from upstream structurally (full module rename plus a
# different web architecture and a re-architected AX adapter), so most upstream
# work is *manually ported*, not cherry-picked. "Absorbed" therefore means
# either of:
#   1. a cherry-pick that recorded `(cherry picked from commit <sha>)` (git -x), or
#   2. an entry in the manual-port ledger docs/upstream-ported.txt
#
# Usage: ./scripts/upstream-pending.sh [--fetch] [--full]
#   --fetch  run `git fetch upstream` first
#   --full   show every pending commit (default: skip merges + caps at 80)
#
# See docs/UPSTREAM.md for the divergence map and the port workflow.

set -e
cd "$(dirname "$0")/.."

REMOTE="upstream"
LEDGER="docs/upstream-ported.txt"
DO_FETCH=0
FULL=0
for a in "$@"; do
    case "$a" in
        --fetch) DO_FETCH=1 ;;
        --full)  FULL=1 ;;
        *) echo "unknown arg: $a" >&2; exit 1 ;;
    esac
done

if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
    echo "error: no '$REMOTE' remote. Run:" >&2
    echo "  git remote add upstream https://github.com/tddworks/baguette.git" >&2
    exit 1
fi

[ "$DO_FETCH" = "1" ] && git fetch "$REMOTE" --tags

BASE="$(git merge-base HEAD "$REMOTE/main")"

# SHAs already absorbed: cherry-pick trailers + manual-port ledger.
PORTED="$(mktemp)"
trap 'rm -f "$PORTED"' EXIT
git log --grep='cherry picked from commit' -E -o --pretty=%b \
    | grep -oE '[0-9a-f]{7,40}' | cut -c1-9 | sort -u > "$PORTED" || true
if [ -f "$LEDGER" ]; then
    grep -oE '^[0-9a-f]{7,40}' "$LEDGER" | cut -c1-9 | sort -u >> "$PORTED" || true
fi
sort -u -o "$PORTED" "$PORTED"

LOG_ARGS=(--reverse --pretty='%h %s')
[ "$FULL" = "1" ] || LOG_ARGS+=(--no-merges)

PENDING=0
echo "Upstream commits not yet absorbed (base $(echo "$BASE" | cut -c1-9) .. $REMOTE/main):"
echo
while read -r sha rest; do
    [ -z "$sha" ] && continue
    short="$(echo "$sha" | cut -c1-9)"
    grep -qx "$short" "$PORTED" && continue
    PENDING=$((PENDING + 1))
    [ "$FULL" = "0" ] && [ "$PENDING" -gt 80 ] && continue
    printf '  %s  %s\n' "$short" "$rest"
done < <(git log "${LOG_ARGS[@]}" "$BASE..$REMOTE/main")

echo
echo "$PENDING pending. Classify each before porting — see docs/UPSTREAM.md:"
echo "  cleanly cherry-pickable : Infrastructure/Input, most of Domain"
echo "  manual port only        : Resources/Web/* , Accessibility adapter"
echo "  after porting, record it in $LEDGER (one '<sha>  note' per line)"
