"""Reference agent-sim verifier — claim-completed-tasks → diff snapshots → pass/fail.

A complement to `agentsim_worker.py`. While the worker drives the simulator
to *make* a change, the verifier reads what a worker submitted, compares
the before/after snapshots, and records a `pass` / `fail` verdict —
without driving the simulator at all. Snapshot-only verification means
the verifier never races a worker on the shared device.

Loop:
    1. Poll `GET /review-tasks.json` (all statuses) for tasks submitted
       by a worker we recognise (prefix match on `assignee`).
    2. Skip if any other task is currently `claimed` (worker mid-flight)
       — the sim-idle gate. Snapshot reads are safe but we keep them out
       of the way of any concurrent capture.
    3. For each candidate: pull the before snapshot (first element's
       `snapshotId`) and the worker-supplied `verificationSnapshotId`.
    4. Compare images perceptually: decode both JPEGs, normalise to a
       small grayscale grid, and take the mean absolute pixel difference
       (Pillow). Falls back to a crude byte-diff when Pillow is absent so
       the script still runs on a bare stdlib.
    5. If clearly different (the screen moved, the worker did something):
       record `pass` with a one-line summary. If identical: `fail` with
       "no visual delta". If ambiguous: leave the task untouched so the
       human operator decides.

Usage:
    python3 agentsim_verifier.py --agent-prefix claude
    python3 agentsim_verifier.py --agent-prefix voyage-claude --interval 3.0

Dependencies: stdlib, plus optional Pillow for the perceptual diff
(`pip install pillow`). Without Pillow it degrades to a crude byte
heuristic. Even the perceptual diff only answers "did the screen
change"; production verifiers should add perceptual hashing or a
vision-model call to judge "does the after-state match the
operator's instructions". This file is a starting point, not the
finished product.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request


def http_get(base: str, path: str) -> object | None:
    try:
        with urllib.request.urlopen(f"{base}{path}", timeout=10) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw.strip() not in ("", "null") else None
    except urllib.error.HTTPError as e:
        sys.stderr.write(f"[verifier] GET {path} → HTTP {e.code}\n")
        return None


def http_post(base: str, path: str, body: dict) -> dict | None:
    req = urllib.request.Request(
        f"{base}{path}",
        data=json.dumps(body).encode("utf-8"),
        headers={"content-type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw.strip() not in ("", "null") else None
    except urllib.error.HTTPError as e:
        sys.stderr.write(f"[verifier] POST {path} → HTTP {e.code}: {e.read().decode('utf-8')}\n")
        return None


def list_tasks(base: str) -> list[dict]:
    """All tasks in any status. We filter client-side so a single fetch
    covers both the sim-idle gate and the readyForVerify candidates.

    The route is `GET /review-tasks.json` (returns a bare JSON array);
    it accepts `?status=` for server-side filtering, but we want every
    status here so the sim-idle gate can see `claimed` tasks too."""
    out = http_get(base, "/review-tasks.json")
    return out if isinstance(out, list) else []


def any_claimed(tasks: list[dict]) -> bool:
    """Sim-idle gate. If any worker is mid-flight, defer verification."""
    return any(t.get("status") == "claimed" for t in tasks)


def candidates(tasks: list[dict], prefix: str, seen: set[str]) -> list[dict]:
    """Tasks submitted by one of our workers, not yet verified by us."""
    return [
        t for t in tasks
        if t.get("status") == "readyForVerify"
        and (t.get("assignee") or "").startswith(prefix)
        and t["id"] not in seen
    ]


def snapshot_path(reviews_root: str, session_id: str, snapshot_id: str) -> str | None:
    """Resolve the on-disk JPEG for a snapshot id by walking the review dir."""
    candidate = os.path.join(reviews_root, session_id, "screenshots", f"{snapshot_id}.jpg")
    return candidate if os.path.exists(candidate) else None


try:
    from PIL import Image  # type: ignore
    _HAVE_PIL = True
except ImportError:  # stdlib-only fallback path
    _HAVE_PIL = False


def byte_diff_ratio(path_a: str, path_b: str) -> float:
    """Crude stdlib-only fallback. Returns 0.0 (identical bytes) to 1.0.

    This is a poor visual signal for JPEGs — the codec scrambles many
    bytes for a small on-screen change, and two visually-identical
    re-encodes differ byte-for-byte. Used only when Pillow is absent;
    `perceptual_diff_ratio` is the real comparison."""
    with open(path_a, "rb") as fa, open(path_b, "rb") as fb:
        a, b = fa.read(), fb.read()
    if a == b:
        return 0.0
    # Compare overlapping bytes; size delta dominates if very different.
    overlap = min(len(a), len(b))
    if overlap == 0:
        return 1.0
    differing = sum(1 for i in range(overlap) if a[i] != b[i])
    size_delta = abs(len(a) - len(b)) / max(len(a), len(b))
    return min(1.0, (differing / overlap) * 0.7 + size_delta * 0.3)


def perceptual_diff_ratio(path_a: str, path_b: str, size: int = 32) -> float:
    """Decode both JPEGs, normalise to a `size`×`size` grayscale grid,
    and return the mean absolute pixel difference in [0.0, 1.0].

    Robust to JPEG byte-noise and re-encode jitter: a re-render with no
    visible change scores ~0, a screen that actually moved scores well
    above the 0.05 pass threshold. Downscaling also makes it cheap and
    resolution-independent (the before/after may differ by a few px)."""
    with Image.open(path_a) as ia, Image.open(path_b) as ib:
        ga = ia.convert("L").resize((size, size))
        gb = ib.convert("L").resize((size, size))
        pa, pb = ga.getdata(), gb.getdata()
    total = sum(abs(x - y) for x, y in zip(pa, pb))
    return min(1.0, total / (len(pa) * 255))


def visual_change_ratio(path_a: str, path_b: str) -> tuple[float, str]:
    """Best available visual-change signal in [0.0, 1.0] + which method
    produced it. Prefers perceptual (Pillow) comparison, falls back to
    the byte heuristic so the verifier still runs on a bare stdlib."""
    if _HAVE_PIL:
        return perceptual_diff_ratio(path_a, path_b), "perceptual"
    return byte_diff_ratio(path_a, path_b), "byte"


def verify_task(base: str, task: dict, reviews_root: str) -> tuple[str, str]:
    """Returns (status, notes) — one of pass / fail / skip.

    `skip` means "ambiguous, leave for human" — do not POST.
    """
    elements = task.get("elements") or []
    if not elements:
        return "skip", "no elements"

    session_id = task["sessionId"]
    before_id = elements[0].get("snapshotId")
    after_id = task.get("verificationSnapshotId")

    if not before_id or not after_id:
        return "skip", "missing before/after snapshot id"

    before_path = snapshot_path(reviews_root, session_id, before_id)
    after_path = snapshot_path(reviews_root, session_id, after_id)
    if not before_path or not after_path:
        return "skip", "snapshot files not on disk"

    ratio, method = visual_change_ratio(before_path, after_path)
    if ratio < 0.01:
        return "fail", f"no visual delta ({method} ratio {ratio:.3f})"
    if ratio > 0.05:
        return "pass", f"visual delta confirmed ({method} ratio {ratio:.3f})"
    return "skip", f"marginal delta ({method} ratio {ratio:.3f}) — operator to decide"


def post_verify(base: str, task: dict, status: str, notes: str) -> None:
    before_ids = [el["snapshotId"] for el in task.get("elements", []) if el.get("snapshotId")]
    body: dict = {
        "status": status,
        "notes": notes,
        "beforeSnapshotIds": list(dict.fromkeys(before_ids)),  # dedupe, preserve order
    }
    if task.get("verificationSnapshotId"):
        body["afterSnapshotId"] = task["verificationSnapshotId"]
    http_post(base, f"/review-tasks/{task['id']}/verify", body)


def loop(base: str, agent_prefix: str, reviews_root: str, interval: float) -> None:
    seen: set[str] = set()
    sys.stdout.write(
        f"[verifier] prefix={agent_prefix} base={base} reviews={reviews_root} every {interval}s\n"
    )
    while True:
        tasks = list_tasks(base)
        if any_claimed(tasks):
            time.sleep(interval)
            continue
        for task in candidates(tasks, agent_prefix, seen):
            status, notes = verify_task(base, task, reviews_root)
            seen.add(task["id"])
            if status == "skip":
                sys.stdout.write(f"[verifier] {task['id']} skipped: {notes}\n")
                continue
            post_verify(base, task, status, notes)
            sys.stdout.write(f"[verifier] {task['id']} {status}: {notes}\n")
        time.sleep(interval)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--agent-prefix", required=True,
                   help="Only verify tasks whose assignee starts with this string")
    p.add_argument("--base", default="http://127.0.0.1:8421")
    p.add_argument("--reviews-root", default=os.path.expanduser("~/.agent-sim/reviews"))
    p.add_argument("--interval", type=float, default=2.0)
    args = p.parse_args()
    loop(args.base, args.agent_prefix, args.reviews_root, args.interval)


if __name__ == "__main__":
    main()
