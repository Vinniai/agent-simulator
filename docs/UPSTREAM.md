# Tracking upstream `tddworks/baguette`

`josh-vincent/agent-sim` is a **clone** (not a GitHub fork) of
[`tddworks/baguette`](https://github.com/tddworks/baguette). We absorb upstream
work selectively. We do **not** do whole-tree merges — the fork has diverged too
far for that to be anything but a perpetual conflict.

## Why not just `git merge upstream/main`?

Three independent sources of divergence:

1. **Full rename.** `baguette → agent-sim` across 235 files, including the SPM
   module name itself (`Sources/Baguette/…` → `Sources/AgentSim/…`,
   `BAGUETTE_WEB_DIR` → `AGENTSIM_WEB_DIR`, `skills/baguette/` →
   `skills/agent-sim/`). Every upstream hunk conflicts on surrounding context.
2. **Web architecture fork.** Upstream rewrote the browser layer into a
   "Baguette SDK" (`Resources/Web/baguette/{baguette,simulator,transport}.js`,
   `baguette/gestures/pointer-interpreter.js`, `baguette/parts/*`). Our fork is
   on the **pre-SDK** stack (`sim-input.js` + `MouseGestureSource` /
   `TouchGestureSource`) and additionally carries a review/queue suite
   (`review-*.js`, `sim-activity.js`, the docks) that upstream never had.
3. **Re-architected subsystems.** e.g. the AX adapter: upstream keeps
   `AXPTranslatorAccessibility.swift` in `Domain/`; we split it into
   `Infrastructure/Accessibility/` with the `AXNode.walk` / `AXFrameTransform`
   pure-core pattern (see `CLAUDE.md`). The files are ~100% divergent.

## Divergence map — what is cherry-pickable vs manual-port

| Area | Maps to our tree? | How to absorb |
|------|-------------------|---------------|
| `Sources/*/Infrastructure/Input/*` | Clean (rename-only) | **cherry-pick** + path remap |
| `Sources/*/Domain/Input/*`, most pure Domain | Usually clean | **cherry-pick** + path remap, verify |
| `Sources/*/App/Commands/*`, `RootCommand.swift` | Mostly clean | **cherry-pick** + path remap, reconcile |
| `Sources/*/Domain|Infrastructure/Accessibility/*` | Re-architected | **manual port** into our split-adapter |
| `Resources/Web/*` (gestures, parts, SDK) | Different architecture | **manual port** into `sim-input.js` etc. |
| `docs/*`, `skills/*`, `CHANGELOG.md` | Renamed paths | port by hand; trivial |
| Camera subsystem (`feat(camera)…`) | New, large, no local equivalent | evaluate as a feature, port deliberately |

"cherry-pick + path remap": `git cherry-pick` will not follow the
`Sources/Baguette/ → Sources/AgentSim/` directory rename. Apply with
`git cherry-pick -x --strategy=recursive -Xrename-threshold=20 <sha>`; if it
lands files under `Sources/Baguette/`, `git mv` them and re-stage. `git rerere`
is enabled (`rerere.autoupdate true`) so the repeated `baguette→agent-sim` hunk
resolutions are recorded once and replayed.

## Workflow

```bash
# 1. see what's new upstream and how it's classified
./scripts/upstream-pending.sh --fetch

# 2a. cherry-pickable Swift commit (clean-mapping area):
git cherry-pick -x <sha>
#    if it added files under Sources/Baguette/, git mv → Sources/AgentSim/, re-stage
swift test                       # must stay green
git commit                       # keep the "(cherry picked from commit <sha>)" trailer

# 2b. manual-port commit (web / AX / renamed paths):
git show <sha>                   # read the intent
#    re-implement the behaviour in our architecture, TDD per CLAUDE.md
echo "<sha>  ported: <one-line what/where>" >> docs/upstream-ported.txt

# 3. verify nothing is missed
./scripts/upstream-pending.sh    # the sha should no longer appear
```

`upstream-pending.sh` treats a commit as absorbed when **either** a
`(cherry picked from commit <sha>)` trailer exists in our history **or** the sha
is listed in `docs/upstream-ported.txt`. Manual ports MUST be recorded in the
ledger or they will resurface forever.

## Ledger

`docs/upstream-ported.txt` — one `<sha>  note` per line. Cherry-picked commits
do **not** need a ledger entry (the `-x` trailer covers them); only manual ports
and deliberate skips do. Mark an intentionally-skipped commit as
`<sha>  skip: <reason>` so it stops showing as pending.
