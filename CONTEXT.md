# Agent Sim

A Swift CLI + web server that turns a booted iOS simulator into the eyes, hands,
and defect-ledger of an autonomous coding agent. It exists to **close a feedback
loop**: an agent ships a feature, agent-simulator verifies it on a real simulator,
files precise defects into a queue, and the agent drains the queue until the
acceptance criteria pass.

## Language

### Core idea

**Agentic Feedback Loop**:
The closed cycle of code → verify-on-simulator → file defects → iterate that
agent-simulator exists to serve. The north star every enhancement is judged against.
_Avoid_: "the agent loop" (overloaded), "automation".

**Device Control**:
The substrate inherited from upstream — boot/stream/inject-gesture against a
simulator without the Simulator.app GUI. Necessary but not the differentiator.
_Avoid_: "core feature" (it's the substrate, not the goal).

### Upstream relationship

**Upstream**:
`tddworks/baguette` — the project agent-simulator was cloned from. Owns Device Control.
_Avoid_: "fork parent" (this is a clone, not a GitHub fork — see `docs/UPSTREAM.md`).

**Absorb**:
To bring an upstream commit into agent-simulator, either by cherry-pick (clean-mapping
areas) or manual port (re-architected areas), recorded so it never resurfaces.
_Avoid_: "merge" (we never whole-tree merge upstream), "sync" (too vague).

**Divergence Surface**:
The code areas where agent-simulator differs from Upstream such that every upstream
hunk conflicts there: the `baguette→agent-simulator` rename, the pre-SDK web stack +
review/queue JS, and the re-architected AX adapter.
_Avoid_: "the diff".

**Tracks-Upstream Surface**:
Code areas that map cleanly to Upstream (rename-only), where an upstream commit
cherry-picks with a path remap. The opposite of Divergence Surface.

### Loop components

**Triangulation**:
Mapping an on-screen element (a device-point x,y) back to the source
file:line:col that rendered it, via AX hit-test → workspace discovery → JSX scan.
_Avoid_: "source mapping", "blame".

**Review Task**:
A unit of agent work in the durable queue — names AX elements to act on, carries
before/after snapshots, and ends in a pass/fail verdict.
_Avoid_: "ticket", "job" (job is an upstream/other concept).

**Note**:
A session-less defect dropped from the UI or CLI, optionally carrying a
Triangulation source pointer; promoted into a Review Task by the loop bridge.
_Avoid_: "comment".

**Quality Gate**:
A score threshold that decides whether a Review Task's after-state passes.

**Acceptance Criterion**:
A first-class, machine-verifiable assertion a Review Task must satisfy — a
**Selector** plus an expectation — checked against the live AX tree to yield a
**Verdict**. The thing that lets the loop self-terminate correctly.
_Avoid_: "test" (reserved for the Swift suite), "check" (too generic).

**Selector**:
How an **Acceptance Criterion** names its target element: `{identifier?, role?,
label?, text?}` matched against the AX tree (set fields ANDed); identifier (= RN
testID) is the recommended primary key. Zero or multiple matches is itself a
reportable outcome. Swift type is `ElementSelector` — the bare name `Selector`
collides with `ObjectiveC.Selector`.
_Avoid_: "query", "locator".

**Verdict**:
The outcome of checking one **Acceptance Criterion** against the live tree:
pass / fail / ambiguous (selector matched zero or many).
_Avoid_: "result" (overloaded with the task's `resultSummary`).

## Relationships

- **Upstream** owns **Device Control**; **Agent Sim** adds the **Agentic Feedback Loop** on top of it.
- A **Note** is promoted into a **Review Task** (the notes→review-task bridge).
- A failed verification produces a **Note** carrying a **Triangulation** pointer.
- An enhancement that lands on the **Divergence Surface** raises **Absorb** cost; one on the **Tracks-Upstream Surface** does not.
- A **Review Task** carries zero or more **Acceptance Criteria**; each pairs a **Selector** with an expectation and resolves to a **Verdict**.
- The loop's exit condition = every **Acceptance Criterion** yields a pass **Verdict** AND the queue has no open **Review Task**.

## Example dialogue

> **Dev:** "Should the new component-tree inspector go in the shared gesture pipeline?"
> **Maintainer:** "No — that's the **Tracks-Upstream Surface**. Putting loop-specific
> logic there turns every upstream gesture commit into a conflict. It belongs in a
> fork-only module so **Absorb** stays cheap. The pipeline only earns changes that
> serve **Device Control** parity with **Upstream**."

## Flagged ambiguities

- "the agent loop" was used for both the **Agentic Feedback Loop** (the concept)
  and `scripts/agent-loop.sh` (one implementation of its plumbing) — the concept
  is the canonical term; the script is just one driver of it.
