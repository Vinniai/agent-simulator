#!/bin/bash
# Cherry-pick an upstream tddworks/baguette commit with automatic path remap.
#
# Applies the four divergence renames documented in docs/UPSTREAM.md before
# `git am --3way`, so commits that only "conflict" because of the
# baguette→agent-simulator rename land cleanly.
#
# Usage: ./scripts/upstream-pick.sh [--force] <upstream-sha>
#   --force   attempt even when the commit touches a manual-port area
#             (Accessibility/, Resources/Web/baguette/, sim-input/stream/native)
#
# Workflow this slots into: see docs/UPSTREAM.md.

set -e
cd "$(dirname "$0")/.."

LEDGER="docs/upstream-ported.txt"
REMOTE="upstream"
FORCE=0
SHA=""
for a in "$@"; do
    case "$a" in
        --force) FORCE=1 ;;
        -*) echo "unknown flag: $a" >&2; exit 1 ;;
        *) SHA="$a" ;;
    esac
done
[ -z "$SHA" ] && { echo "usage: $0 [--force] <upstream-sha>" >&2; exit 1; }

FULL="$(git rev-parse "$SHA" 2>/dev/null)" || { echo "bad sha: $SHA" >&2; exit 1; }
SHORT="$(echo "$FULL" | cut -c1-9)"

# Already absorbed?
if [ -f "$LEDGER" ] && grep -qE "^${SHORT}" "$LEDGER"; then
    echo "already in ledger: $SHORT"; exit 0
fi
if git log --grep="cherry picked from commit $FULL" --format=%h | grep -q .; then
    echo "already cherry-picked: $SHORT"; exit 0
fi

# Classify against the divergence map in docs/UPSTREAM.md
FILES="$(git show --name-only --format= "$FULL")"
MANUAL_HITS="$(echo "$FILES" | grep -E '(Accessibility/|Resources/Web/baguette/|sim-(input|stream|native)\.(js|html))' || true)"
if [ -n "$MANUAL_HITS" ] && [ "$FORCE" = "0" ]; then
    echo "$SHORT touches manual-port areas:"
    echo "$MANUAL_HITS" | sed 's/^/  /'
    echo
    echo "These re-architected subsystems need hand porting (see docs/UPSTREAM.md)."
    echo "Re-run with --force to attempt the rewrite anyway."
    exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git format-patch -1 "$FULL" --stdout > "$TMP/orig.patch"

# Documented renames, applied to the patch headers + bodies.
# Path renames are the high-value ones; the two string renames cover the
# residual divergence in shared files like AXPTranslatorAccessibility.swift.
sed \
    -e 's|Sources/Baguette/|Sources/AgentSim/|g' \
    -e 's|Tests/BaguetteTests/|Tests/AgentSimTests/|g' \
    -e 's|skills/baguette/|skills/agent-simulator/|g' \
    -e 's|BAGUETTE_WEB_DIR|AGENTSIM_WEB_DIR|g' \
    -e 's|baguette\.ax\.xpc|agent-simulator.ax.xpc|g' \
    -e "s|baguette's gesture wire|agent-simulator's gesture wire|g" \
    "$TMP/orig.patch" > "$TMP/rewritten.patch"

# Inject "(cherry picked from commit <full>)" trailer before the diff separator
# so `git am` records it the same way `cherry-pick -x` would.
awk -v sha="$FULL" '
    /^---$/ && !done { print "(cherry picked from commit " sha ")"; print ""; done=1 }
    { print }
' "$TMP/rewritten.patch" > "$TMP/final.patch"

if git am --3way "$TMP/final.patch"; then
    echo
    echo "OK  $SHORT cherry-picked with path rewrite."
    exit 0
fi

echo
echo "am failed for $SHORT. Diagnostics:"
UNMERGED="$(git diff --name-only --diff-filter=U 2>/dev/null || true)"
if [ -n "$UNMERGED" ]; then
    echo "  unmerged paths:"
    echo "$UNMERGED" | sed 's/^/    /'
    # For modify/delete, point at the upstream commit that added each file —
    # picking that first usually unsticks the rest.
    for f in $UNMERGED; do
        ADDS="$(git log --diff-filter=A --format='%h %s' "HEAD..$REMOTE/main" -- "$f" 2>/dev/null | head -3)"
        if [ -n "$ADDS" ]; then
            echo "  $f was added upstream by:"
            echo "$ADDS" | sed 's/^/    /'
        fi
    done
fi
echo
echo "Resolve conflicts then 'git am --continue', or 'git am --abort' to back out."
exit 1
