# Formalize a fork-only vs tracks-upstream boundary

## Status

accepted

## Context

agent-simulator is a selective clone of `tddworks/baguette` (see `docs/UPSTREAM.md`): we
absorb upstream Device Control improvements but never whole-tree merge. The fork's
reason to exist is the **Agentic Feedback Loop** (see `CONTEXT.md`), not device
control. Every change we make to code that maps cleanly to upstream raises the cost
of future cherry-picks; changes confined to fork-only code cost nothing at absorb
time.

## Decision

Treat the codebase as two explicit zones and keep loop value out of the
upstream-shared zone:

- **Tracks-Upstream Surface** — `Input`, `Screen`, `Stream`, `Simulator`, `Chrome`
  contexts and the device-control routes. Kept as close to upstream's shape as
  possible so a commit cherry-picks with only a path remap.
- **Fork-Only Surface** — `Review`, `Notes`, `Workspace` (triangulation),
  `Diagnostics`, the agent loop, and their routes/web assets. All loop enhancements
  land here and may evolve freely.

Enforce the boundary pragmatically rather than by module split (for now):

1. Extract the loop routes inlined in the 2,483-line `Server.swift` into a fork-only
   route registration, leaving `Server.swift` as thin upstream-shaped wiring plus one
   call into the loop routes.
2. Enumerate fork-only paths in a manifest (e.g. `docs/fork-only.txt`).
3. A CI guard fails when a tracks-upstream file references fork-only contexts, or when
   a new top-level source file is unclassified.

## Considered options

- **Separate SPM module (`AgentSimCore` + `AgentSimLoop`)** — compiler-enforced
  boundary, strongest guarantee, but a large refactor and the `baguette→agent-simulator`
  rename still bites Core. Held as the possible stronger form if the boundary proves
  valuable.
- **Convention only** — naming/dir rule with no guard. Rejected: nothing stops the
  next `Server.swift`.

## Consequences

- The AX adapter re-architecture and the pre-SDK web stack remain manual-port
  divergences; we accept them as fixed cost rather than converging back.
- The Server route extraction and the web `Resources/Web/` flat dir (where `sim-*`
  shared and `review-*` fork-only assets intermix) are the first cleanups this
  boundary implies.
