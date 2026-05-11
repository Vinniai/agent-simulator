"""Convert an agent-canvas route manifest into a agent-sim review-tasks bulk-create
envelope.

agent-canvas (https://github.com/EvanBacon/serve-sim style, or the local
`../agent-canvas` package) walks an Expo Router app's routes and emits
`agent-canvas/latest/manifest.json` — one entry per route with a
screenshot, AX element bounds, and any pasted React Native Grab
selection. This script reads that manifest and produces a JSON envelope
suitable for `agent-sim review-tasks bulk-create --file -`, so the
operator can queue one review task per route in a single shell
pipeline.

Usage:
    python3 agent_canvas_to_baguette.py \\
        --manifest path/to/agent-canvas/latest/manifest.json \\
        --session-id review-xyz \\
        | agent-sim review-tasks bulk-create --session-id review-xyz --file -

Required input fields per route (rest are tolerated and ignored):
    urlPath:       the Expo route path (used as task title fallback)
    title:         human-readable label (used as task title when present)
    notes/comments: array of {text} or string (used as instructions)
    elements:      array of element descriptors with `id` / `frame`

The script is intentionally lenient about manifest shape — different
agent-canvas captures emit slightly different JSON depending on the
`--element-provider` flag. Any element without an addressable id is
dropped silently; the route still becomes a task.

What this script does NOT do:
    - Import agent-canvas's PNG screenshots into agent-sim's snapshot
      store. Until that adapter lands, the bulk-created tasks reference
      `snapshotId` values that don't exist in agent-sim's review session.
      You can still claim/work/verify them, but the operator's review
      browser won't render before/after screenshots for these. Treat
      them as "external-source tasks" that pipe through agent-canvas
      separately.

Dependencies: stdlib only.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def load_manifest(path: Path) -> dict:
    raw = json.loads(path.read_text())
    if isinstance(raw, list):
        # Some agent-canvas variants emit a bare array.
        return {"routes": raw}
    return raw


def comments_to_instructions(value) -> str | None:
    """agent-canvas emits comments as either a list of {text:...}, a
    list of strings, or a top-level `notes` string. Try them all."""
    if value is None:
        return None
    if isinstance(value, str):
        return value.strip() or None
    if isinstance(value, list):
        parts: list[str] = []
        for entry in value:
            if isinstance(entry, str):
                parts.append(entry.strip())
            elif isinstance(entry, dict):
                text = entry.get("text") or entry.get("body") or entry.get("note")
                if isinstance(text, str):
                    parts.append(text.strip())
        joined = "\n".join(p for p in parts if p)
        return joined or None
    return None


def element_inputs(route: dict) -> list[dict]:
    out: list[dict] = []
    raw_elements = route.get("elements") or []
    for el in raw_elements:
        if not isinstance(el, dict):
            continue
        # Prefer a stable id from the element; fall back to route path so
        # the task still attaches to something traceable.
        snap = (
            el.get("snapshotId")
            or el.get("snapshot")
            or el.get("imageId")
            or el.get("screenshotId")
            or route.get("snapshotId")
            or route.get("screenshotId")
            or route.get("id")
            or route.get("urlPath")
        )
        if not isinstance(snap, str) or not snap:
            continue
        ax_path = (
            el.get("axNodePath")
            or el.get("axPath")
            or el.get("path")
            or "/"
        )
        out.append({
            "snapshotId": snap,
            "axNodePath": ax_path,
            "commentText": el.get("commentText") or el.get("note"),
        })
    return out


def route_to_item(route: dict) -> dict | None:
    url = route.get("urlPath") or route.get("url") or route.get("path")
    title = route.get("title") or url or route.get("id")
    if not title:
        return None
    instructions = (
        comments_to_instructions(route.get("notes"))
        or comments_to_instructions(route.get("comments"))
        or comments_to_instructions(route.get("annotations"))
    )
    return {
        "title": str(title),
        "instructions": instructions,
        "elements": element_inputs(route),
    }


def build_envelope(manifest: dict, session_id: str, assignee: str | None) -> dict:
    routes = manifest.get("routes") or manifest.get("entries") or manifest.get("items") or []
    if not isinstance(routes, list):
        sys.stderr.write("[adapter] manifest has no routes/entries/items array; aborting\n")
        sys.exit(1)
    tasks = [item for r in routes if isinstance(r, dict) for item in [route_to_item(r)] if item]
    if not tasks:
        sys.stderr.write("[adapter] manifest yielded zero tasks; nothing to emit\n")
        sys.exit(2)
    envelope = {
        "sessionId": session_id,
        "tasks": tasks,
    }
    if assignee:
        envelope["defaults"] = {"assignee": assignee}
    return envelope


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--manifest", required=True, type=Path,
                   help="Path to agent-canvas/latest/manifest.json")
    p.add_argument("--session-id", required=True,
                   help="Existing agent-sim review session id every task attaches to")
    p.add_argument("--assignee", default=None,
                   help="Optional default assignee for every emitted task")
    args = p.parse_args()
    if not args.manifest.exists():
        sys.stderr.write(f"[adapter] manifest not found: {args.manifest}\n")
        sys.exit(1)
    manifest = load_manifest(args.manifest)
    envelope = build_envelope(manifest, args.session_id, args.assignee)
    json.dump(envelope, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
