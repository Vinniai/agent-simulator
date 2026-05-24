"""Reference agent-sim worker — claim → tap → capture → submit.

A self-contained, dependency-light Python loop that demonstrates the
full agent protocol described in `docs/AGENT-API.md`. Copy this file
into your own project as a starting point. It is NOT compiled into
the agent-sim binary and has no test coverage of its own — the wire
contract it depends on is what's tested.

Usage:
    python3 agentsim_worker.py --agent-id my-agent
    python3 agentsim_worker.py --agent-id my-agent --base http://127.0.0.1:8421

Dependencies: stdlib + `websocket-client` (`pip install websocket-client`).

MCP-shaped variant (sketch — not implemented here):
    Wrap the step functions below as MCP tools so a host agent
    (e.g. Claude Code) can invoke them as discrete actions instead of
    running the polling loop:
        - claim_next_task(agent_id)                  -> ReviewTask | None
        - tap_element(udid, element_id)              -> {ok: bool}
        - post_code_changes(task_id, agent_id, list) -> None
        - capture_state(session_id, udid, from)      -> snapshot_id
        - submit_result(task_id, status, ...)        -> ReviewTask
    Each tool wraps a single HTTP / WS call from this file. Drop the
    while-loop; the host agent decides when each tool fires.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request

import websocket  # type: ignore[import-not-found]


def post(base: str, path: str, body: dict) -> dict | None:
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
        sys.stderr.write(f"[agent] {path} → HTTP {e.code}: {e.read().decode('utf-8')}\n")
        raise


def claim_next(base: str, agent_id: str) -> dict | None:
    return post(base, "/agent/tasks/next", {"agentId": agent_id})


def emit_event(base: str, task_id: str, agent_id: str, msg: str, kind: str = "progress") -> None:
    post(base, f"/agent/tasks/{task_id}/events", {
        "type": kind,
        "actor": agent_id,
        "message": msg,
    })


def capture_after(base: str, session_id: str, udid: str, from_snap: str | None) -> str | None:
    body: dict = {"udid": udid, "actionType": "agent"}
    if from_snap:
        body["fromSnapshotId"] = from_snap
    result = post(base, f"/reviews/{session_id}/capture", body)
    return result["snapshot"]["id"] if result else None


def submit_result(
    base: str,
    task_id: str,
    agent_id: str,
    summary: str,
    verification_snapshot_id: str | None,
    status: str = "readyForVerify",
) -> None:
    post(base, f"/agent/tasks/{task_id}/result", {
        "status": status,
        "actor": agent_id,
        "resultSummary": summary,
        "verificationSnapshotId": verification_snapshot_id,
    })


def post_code_changes(base: str, task_id: str, agent_id: str, changes: list[dict]) -> None:
    """Record the source-file modifications the agent made for this task.

    Each change is a dict matching ReviewTaskCodeChangeInput in the
    Swift Domain: {path, summary, startLine, endLine, commitSha,
    branch, language, diffText}. `path` should be an absolute path so
    the review UI's vscode://file/<path>:<line> link resolves on the
    operator's machine. `diffText` is capped server-side at 256 KB.
    """
    if not changes:
        return
    post(base, f"/agent/tasks/{task_id}/code-changes", {
        "actor": agent_id,
        "changes": changes,
    })


def root_screen_size(task: dict) -> tuple[float, float] | None:
    """Derive (width, height) from the largest element frame in the task.

    The root AX element (an AXApplication-level node) covers the whole
    screen, so its frame doubles as the device-point screen size.
    """
    frames = [el.get("frame") for el in task.get("elements", []) if el.get("frame")]
    if not frames:
        return None
    biggest = max(frames, key=lambda f: f["width"] * f["height"])
    return biggest["width"], biggest["height"]


def execute_task(base: str, task: dict, agent_id: str, udid: str) -> None:
    # ReviewTask.elements[*] carry only `snapshotId`, not a UDID, and
    # ReviewSession.devices[] can hold more than one. A real worker
    # should fetch the session and resolve the UDID for each
    # element.snapshotId. For this reference we run in single-device
    # mode: the operator passes --udid on the CLI.
    size = root_screen_size(task)
    if not size:
        emit_event(base, task["id"], agent_id, "no element frames; bailing", "error")
        submit_result(base, task["id"], agent_id, "no actionable elements", None, "failed")
        return
    width, height = size

    # One long-lived WS for this task's UDID.
    ws_url = f"{base.replace('http', 'ws', 1)}/simulators/{udid}/stream?format=mjpeg"
    ws = websocket.create_connection(ws_url, timeout=5)
    try:
        for el in task["elements"]:
            f = el.get("frame")
            if not f:
                continue
            cx = f["x"] + f["width"] / 2
            cy = f["y"] + f["height"] / 2
            ws.send(json.dumps({
                "type": "tap",
                "x": cx, "y": cy,
                "width": width, "height": height,
                "duration": 0.05,
            }))
            emit_event(
                base, task["id"], agent_id,
                f"tapped {el.get('role')} '{el.get('label')}' at ({cx:.0f}, {cy:.0f})",
            )
            time.sleep(0.4)  # let the UI settle before the next action / capture
    finally:
        ws.close()

    before_snap = task["elements"][0].get("snapshotId") if task.get("elements") else None
    after_snap = capture_after(base, task["sessionId"], udid, before_snap)
    submit_result(
        base, task["id"], agent_id,
        summary=f"executed {len(task['elements'])} taps",
        verification_snapshot_id=after_snap,
    )


def loop(base: str, agent_id: str, poll_sec: float, udid: str) -> None:
    sys.stdout.write(f"[agent] {agent_id} polling {base} every {poll_sec}s (udid={udid})\n")
    while True:
        task = claim_next(base, agent_id)
        if not task:
            time.sleep(poll_sec)
            continue
        sys.stdout.write(f"[agent] claimed {task['id']}: {task['title']}\n")
        try:
            execute_task(base, task, agent_id, udid)
            sys.stdout.write(f"[agent] submitted result for {task['id']}\n")
        except Exception as e:  # noqa: BLE001 — reference agent, keep simple
            sys.stderr.write(f"[agent] {task['id']} failed: {e}\n")
            submit_result(base, task["id"], agent_id, f"agent error: {e}", None, "failed")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--agent-id", required=True)
    p.add_argument("--udid", required=True, help="UDID this worker drives (single-device mode)")
    p.add_argument("--base", default="http://127.0.0.1:8421")
    p.add_argument("--poll", type=float, default=2.0)
    args = p.parse_args()
    loop(args.base, args.agent_id, args.poll, args.udid)


if __name__ == "__main__":
    main()
