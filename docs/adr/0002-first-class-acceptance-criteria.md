# First-class Acceptance Criteria verified against AX snapshots

## Status

accepted

## Context

The Agentic Feedback Loop (see `CONTEXT.md`) needs to *self-terminate correctly*:
stop only when the feature actually works. Today acceptance criteria live in the
agent's prompt and the loop trusts the agent's prose judgment; the snapshot verifier
(`examples/agent/agentsim_verifier.py`) only answers "did the screen change"
(pixel-diff), not "does it match the criterion". We are making criteria a
machine-verifiable, first-class part of a Review Task.

## Decision

Add a fork-only **Verification** bounded context (`Domain/Verification/`) holding the
value types and a pure engine:

- **Selector** (Swift type `ElementSelector` — the bare name `Selector` collides with
  `ObjectiveC.Selector`) — `{identifier?, role?, label?, text?}`, set fields ANDed
  against an AX tree; identifier (= RN testID) is the recommended primary key. Zero or
  multiple matches is a reportable outcome, not an error.
- **Acceptance Criterion** — a Selector + an expectation from a minimal-but-complete
  vocabulary: `exists | absent | enabled | disabled | text{equals|contains}` (text
  matches `label` or `value`). The Swift type is `ExpectedState` — the bare name
  `Expectation` collides with `Testing.Expectation`, in scope in every test file,
  the same way `Selector` collided with `ObjectiveC.Selector`. It encodes to a
  `kind`-tagged object (`{"kind":"textEquals","text":"…"}`) so authored JSON stays
  legible.
- **Verdict** — pass / fail / ambiguous, with a reason.
- **`CriteriaCheck.run(tree:criteria:) -> [Verdict]`** — pure; unit-tested with
  fixture `AXNode` trees, no simulator.

A `ReviewTask` gains `criteria: [AcceptanceCriterion]` (authored at task creation,
same way `elements` are) and `verdicts: [Verdict]` (stored like `events` /
`codeChanges`).

- **Input:** snapshot by default — decode the verification snapshot's already-persisted
  `axPath` — with a `--live` flag to run against fresh `describe-ui`. One engine, two
  tree-providers.
- **Effect:** **authoritative** — verdicts drive status (all-pass → `verified`, any
  fail/ambiguous → `open`). The loop's exit condition becomes computed (no open tasks
  ⇒ all criteria pass), not prose-judged.
- **Surface:** a CLI `review-tasks verify` + an HTTP route, both registered in the new
  fork-only loop-routes file (per ADR-0001), not inlined into `Server.swift`.

## Considered options

- **Selector:** label-only (fragile on repeats/rewording) and AX-node-path (brittle
  across exactly the re-renders we re-verify after) were rejected in favour of the
  structured, identifier-first selector.
- **Verdict effect:** advisory (verdicts stored but status manual) was rejected — it
  leaves termination to agent discipline, defeating the purpose.
- **Auto-run on `readyForVerify`:** offered as **opt-in only**, never default. The
  worry was a wrong-screen snapshot auto-failing an otherwise-good task, so grading
  stays off until the caller explicitly asks: `review-tasks result --auto-verify`,
  or `?verify=1` on the task-update/result route. When opted in it records the
  result then grades the criteria against the just-attached snapshot in one call
  (`LoopRoutes.submitResult`); a fail only sends the task back to `open`
  (recoverable). Default-on auto-grading remains rejected for the same reason.

## Consequences

- Snapshot-default verification is reproducible and replayable, and the snapshot-only
  verifier daemon can run it without racing a worker on the device.
- The `--live` path adds a second tree-provider (extra test matrix) but no second engine.
- This is the first feature to land its routes in the extracted fork-only loop-routes
  file, exercising the ADR-0001 boundary in practice.
