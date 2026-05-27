# Review-task code changes

Track and surface the underlying source-file modifications an agent makes
for a queued `ReviewTask`. The reviewer (human or downstream agent) sees,
in one place:

- The operator's **original instructions** (already on `ReviewTask.instructions`).
- The **before / after snapshots** of the simulator (already on `ReviewTaskVerification`).
- The **list of files the agent changed** — path, summary, line range,
  commit SHA, branch, and an expandable unified diff — with a clickable
  `vscode://file/…` link that opens the file at the changed line in VSCode
  on the operator's machine.

The agent self-reports these records via one HTTP call; the review web UI
renders them under each task card; the existing
`WS /review-tasks/stream` lights up without new wiring.

## Wire JSON

```json
POST /agent/tasks/:id/code-changes
{
  "actor": "claude-code-mcp@laptop-01",
  "changes": [
    {
      "path":      "/abs/path/Sources/Save/SaveButton.swift",
      "summary":   "added validation on submit",
      "startLine": 42,
      "endLine":   58,
      "commitSha": "abc123def",
      "branch":    "main",
      "language":  "swift",
      "diffText":  "@@ -42,7 +42,12 @@\n-  func handleSave() {\n+  func handleSave() {\n+    guard validate() else { return }"
    }
  ]
}
```

Required: `path`. Everything else is optional but the more you supply the
richer the review surface gets.

The mirror route `POST /review-tasks/:id/code-changes` accepts the exact
same body and is intended for operator / CLI use rather than agent use —
they share the same handler and persist into the same table.

Response is the full updated `ReviewTask`:

```json
{ "id": "task_01HXZ…",
  "status": "claimed",
  "codeChanges": [
    { "id": "cc_01HX…",
      "path": "/abs/path/Sources/Save/SaveButton.swift",
      "summary": "added validation on submit",
      "startLine": 42, "endLine": 58,
      "commitSha": "abc123def", "branch": "main",
      "language": "swift",
      "diffText": "@@ -42,7 +42,12 @@…",
      "createdAt": "2026-05-11T13:45:02Z" }
  ],
  "events": [
    …,
    { "type": "code_changes", "actor": "claude-code-mcp@laptop-01",
      "message": "Recorded 1 code change", "createdAt": "2026-05-11T13:45:02Z" }
  ]
}
```

## CLI mirror

Single change via flags:

```bash
agent-simulator review-tasks add-code-change task_42 \
    --path Sources/Save/SaveButton.swift \
    --summary "added validation on submit" \
    --start-line 42 --end-line 58 \
    --commit-sha "$(git rev-parse HEAD)" \
    --branch "$(git rev-parse --abbrev-ref HEAD)" \
    --language swift \
    --diff-file /tmp/savebutton.diff \
    --actor claude-code-mcp@laptop-01
```

Batch from a JSON array of `ReviewTaskCodeChangeInput`:

```bash
agent-simulator review-tasks add-code-change task_42 --changes-file changes.json
```

Use `--diff-file` to point at a file containing the unified diff —
avoids shell-quoting pain for multi-line content.

## Dispatch path

```
Wire JSON                  Domain                              Infrastructure
POST /agent/tasks/:id/     ┌─────────────────────────┐         ┌────────────────────────┐
  code-changes        ──▶  │ ReviewTaskCodeChange    │         │ SQLiteReviewTaskStore  │
  + actor +                │ ReviewTaskCodeChangeInput│ ──────▶│ .appendCodeChanges     │
  ReviewTaskCodeChange[]   │ ReviewTaskCodeChangesInput│        │   - INSERT rows        │
                           │ ReviewTaskStore proto    │        │   - emit code_changes  │
                           │   + appendCodeChanges    │        │     event              │
                           └─────────────────────────┘         │   - re-hydrate task    │
                                    ▲                          └────────────────────────┘
       CLI ─── ArgumentParser ──────┤                                     │
       (review-tasks add-code-change)                                     ▼
       Server ─── /agent/tasks/:id/code-changes                  /review-tasks/stream
              └── /review-tasks/:id/code-changes                    task_update fan-out
       Browser ─── review-code-changes.js (rendered into review.js task cards)
```

## Where each detail comes from

| Field | Source | Why it matters |
|---|---|---|
| `path` | What the agent edited | Powers the `vscode://file/<path>:<startLine>` link |
| `summary` | One-line agent note | Lets the reviewer skim without expanding the diff |
| `startLine` / `endLine` | Line range of change | Drives the VSCode-link line jump and the `path:L-L` label |
| `commitSha` / `branch` | `git rev-parse HEAD` / `--abbrev-ref` | Persists which commit produced the after-state |
| `language` | File extension hint | Reserved for future per-language diff highlighting (today: text only) |
| `diffText` | `git diff <pre-claim-sha>..HEAD -- <path>` | Inline review without leaving the page |

## Adding a new field

1. Add the field to `ReviewTaskCodeChange` + `ReviewTaskCodeChangeInput`
   in `Sources/AgentSim/Domain/Review/ReviewTaskModels.swift`. If it can
   be missing on legacy rows, use `decodeIfPresent` in the custom
   `ReviewTask` decoder (mirrors how `flows` / `recordings` /
   `codeChanges` itself were rolled in).
2. Add a column to the `review_task_code_changes` table in
   `SQLiteReviewTaskStore.migrate()` — bump it via `CREATE TABLE IF NOT
   EXISTS …` if you're starting fresh, or via an `ALTER TABLE … ADD
   COLUMN …` for backwards-compatible rollouts.
3. Read it back in `queryCodeChanges` (mind the column order — the
   `text(stmt, N)` index is positional).
4. Surface it in `review-code-changes.js` via `textContent` (never
   `innerHTML` — agent-supplied strings must not be HTML-injected).
5. Bump `docs/AGENT-API.md`, this file, and a CHANGELOG entry.

## Known limits

- **No git auto-population.** The agent must POST what it changed. A
  future `agent-simulator review-tasks add-code-change --auto --since-claim`
  helper could read git for you; today you wire the call yourself.
- **`vscode://` links require an absolute path.** Relative paths render
  as text only; the link target won't resolve.
- **`diffText` is capped at 256 KB** server side. Larger diffs are
  stored truncated with a `[…truncated]` marker; the agent should
  pre-trim if it cares about the tail.
- **No syntax highlighting.** The diff renders as monochrome
  `<pre>` text. `language` is stored for forward compatibility.
- **No per-file authorship.** All changes from one `POST` share the
  same `actor`. Send multiple requests if you need per-file actors.
