#!/bin/bash
# Enforce the fork-only vs tracks-upstream boundary (ADR-0001).
#
# Source of truth: docs/fork-only.txt. Two checks:
#   1. completeness — every context dir under Domain/ and Infrastructure/, and
#      every .swift under App/ and App/Commands/, is classified in exactly one
#      [classify:*] section. A new unclassified top-level source file fails,
#      forcing a conscious fork-only/tracks-upstream decision.
#   2. leakage — no file in a tracks-upstream context references a fork-only type
#      from [markers]. Such a reference would couple the upstream-shared zone to
#      loop value and break the next cherry-pick.
#
# Exit: 0 = boundary intact · 1 = a violation (use in CI / pre-push) ·
#       2 = environment problem (manifest or source tree missing).
#
# Deps: awk, grep (BSD or GNU). No bash-4 features (runs on macOS bash 3.2).

set -euo pipefail
cd "$(dirname "$0")/.."

MANIFEST="docs/fork-only.txt"
SRC="Sources/AgentSim"
[ -f "$MANIFEST" ] || { echo "error: $MANIFEST not found" >&2; exit 2; }
[ -d "$SRC" ]      || { echo "error: $SRC not found" >&2; exit 2; }

# classified <layer> <category> → bare names declared under that section.
classified() {
    awk -v layer="$1" -v cat="$2" '
        /^\[/ { inblk = ($0 ~ "^\\[classify:" layer "\\] " cat "$") ? 1 : 0; next }
        inblk && NF && $0 !~ /^#/ { print $1 }
    ' "$MANIFEST"
}
# all names classified for a layer, across every category.
classified_all() {
    for c in tracks-upstream fork-only diverged shared; do classified "$1" "$c"; done
}
markers() {
    awk '/^\[markers\]/{inblk=1;next} /^\[/{inblk=0} inblk && NF && $0 !~ /^#/{print $1}' "$MANIFEST"
}

VIOLATIONS=0
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; VIOLATIONS=$((VIOLATIONS + 1)); }

echo "── fork-only boundary (ADR-0001) ──"

# ── 1. Completeness ───────────────────────────────────────────────────────
# Actual top-level names per layer, compared against the manifest both ways:
# anything on disk but unclassified fails; anything classified but absent is a
# stale manifest entry (also fails — keeps the manifest honest).
check_layer() {
    local layer="$1" actual="$2"   # actual = newline-separated names on disk
    local declared; declared="$(classified_all "$layer" | sort -u)"
    local got; got="$(printf '%s\n' "$actual" | sed '/^$/d' | sort -u)"

    while IFS= read -r name; do
        [ -n "$name" ] || continue
        printf '%s\n' "$declared" | grep -qxF "$name" \
            || fail "[$layer] '$name' is unclassified — add it to a [classify:$layer] section in $MANIFEST"
    done <<EOF
$got
EOF

    while IFS= read -r name; do
        [ -n "$name" ] || continue
        printf '%s\n' "$got" | grep -qxF "$name" \
            || fail "[$layer] '$name' is classified in $MANIFEST but no longer exists on disk (stale entry)"
    done <<EOF
$declared
EOF
}

check_layer domain         "$(ls -1 "$SRC/Domain")"
check_layer infrastructure "$(ls -1 "$SRC/Infrastructure")"
check_layer app            "$( { ls -1 "$SRC/App"/*.swift "$SRC/App/Commands"/*.swift; } 2>/dev/null | xargs -n1 basename )"

# ── 2. Leakage ────────────────────────────────────────────────────────────
# Resolve every tracks-upstream entry to its path(s), then grep for any marker
# as a whole word. Diverged/shared entries are exempt as a leak *source*.
MARKERS="$(markers)"
[ -n "$MARKERS" ] || { echo "error: no [markers] in $MANIFEST" >&2; exit 2; }

scan_path() {
    local path="$1"
    [ -e "$path" ] || return 0
    local m
    for m in $MARKERS; do
        local hits
        hits="$(grep -rlw "$m" "$path" --include='*.swift' 2>/dev/null || true)"
        if [ -n "$hits" ]; then
            while IFS= read -r f; do
                fail "tracks-upstream file references fork-only type '$m': ${f#./}"
            done <<EOF
$hits
EOF
        fi
    done
}

for name in $(classified domain tracks-upstream);         do scan_path "$SRC/Domain/$name"; done
for name in $(classified infrastructure tracks-upstream); do scan_path "$SRC/Infrastructure/$name"; done
for name in $(classified app tracks-upstream); do
    # an app entry is a filename; it may live in App/ or App/Commands/.
    for p in "$SRC/App/$name" "$SRC/App/Commands/$name"; do scan_path "$p"; done
done

# ── Verdict ─────────────────────────────────────────────────────────────────
if [ "$VIOLATIONS" -eq 0 ]; then
    printf '  \033[32mOK\033[0m boundary intact (%d markers, all contexts classified)\n' "$(printf '%s\n' "$MARKERS" | grep -c .)"
    exit 0
fi
echo "──────────────────────────────────────────────"
echo "$VIOLATIONS boundary violation(s). See ADR-0001 and $MANIFEST."
exit 1
