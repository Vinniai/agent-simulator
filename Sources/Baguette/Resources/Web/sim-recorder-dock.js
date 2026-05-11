// sim-recorder-dock.js — flow recorder + saved-flow list mounted in
// the Review Mapping sidebar (farm focus) and any sibling host on
// /simulators/:udid.
//
// Wire surface
//   window.BaguetteFlowRecorder
//     .start({ sessionId, name })  // begin capturing wire envelopes
//     .stop()                       // POST captured steps to /reviews/:id/flows
//     .isRecording                  // bool
//     .mount({ host, getSessionId, getUdid }) → { unmount, refresh }
//
// Capture strategy
//   We patch SimInputBridge.makeTransport so every wire envelope
//   bound for the simulator (tap / swipe / touch1-* / touch2-* /
//   button / scroll / key / type) is also published to the recorder
//   *before* hitting the WS. The envelopes are exactly the shape the
//   server's FlowReplayService re-dispatches — no translation layer.
(function () {
  'use strict';

  const state = {
    active: false,
    startedAt: 0,
    steps: [],
    sessionId: '',
    patched: false,
  };

  // Idempotent monkey-patch: each transport returned by
  // SimInputBridge.makeTransport gets a peek hook installed once.
  function ensurePatched() {
    if (state.patched) return;
    if (!window.SimInputBridge || typeof window.SimInputBridge.makeTransport !== 'function') return;
    const orig = window.SimInputBridge.makeTransport.bind(window.SimInputBridge);
    window.SimInputBridge.makeTransport = function (session, log) {
      const send = orig(session, log);
      return function (payload) {
        if (state.active) {
          try {
            const wire = window.SimInputBridge.toBaguetteWire(payload, log);
            if (wire && wire.type) {
              const step = Object.assign({}, wire);
              step.delayMs = Math.max(0, Math.round(performance.now() - state.startedAt));
              state.steps.push({ type: wire.type, payload: dropType(step) });
            }
          } catch (_) { /* never block transport on recorder bugs */ }
        }
        return send(payload);
      };
    };
    state.patched = true;
  }

  function dropType(o) {
    const out = {};
    for (const k of Object.keys(o)) if (k !== 'type') out[k] = o[k];
    return out;
  }

  function start({ sessionId } = {}) {
    ensurePatched();
    state.steps = [];
    state.sessionId = sessionId || '';
    state.startedAt = performance.now();
    state.active = true;
  }

  async function stop({ name } = {}) {
    if (!state.active) return null;
    state.active = false;
    const captured = state.steps.slice();
    state.steps = [];
    if (!captured.length || !state.sessionId) return null;
    const body = {
      name: (name || `Flow · ${new Date().toLocaleString()}`).slice(0, 120),
      steps: captured.map(stepToJSONValue),
      createdBy: 'sim-recorder-dock',
    };
    try {
      const res = await fetch(`/reviews/${encodeURIComponent(state.sessionId)}/flows`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return await res.json();
    } catch (e) {
      console.warn('[recorder] save failed:', e);
      return null;
    }
  }

  // FlowStep payload is `[String: JSONValue]` on the wire (Codable
  // round-trips JSONValue.number, JSONValue.string, etc). Wire
  // envelopes are already primitive Numbers / Strings, so a flat
  // copy maps 1:1 — JSONEncoder's single-value container does the
  // discriminator work on the server side.
  function stepToJSONValue(step) {
    return { type: step.type, payload: step.payload };
  }

  async function listFlows(sessionId) {
    if (!sessionId) return [];
    try {
      const res = await fetch(`/reviews/${encodeURIComponent(sessionId)}/flows.json`);
      if (!res.ok) return [];
      const arr = await res.json();
      return Array.isArray(arr) ? arr : [];
    } catch (_) { return []; }
  }

  async function replay({ sessionId, flowId, udid, pacing }) {
    const res = await fetch(`/reviews/${encodeURIComponent(sessionId)}/flows/${encodeURIComponent(flowId)}/replay`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ udid, pacing: pacing || 'fast' }),
    });
    if (!res.ok) throw new Error(await res.text());
    return await res.json();
  }

  function escapeHTML(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    })[c]);
  }

  function mount({ host, getSessionId, getUdid }) {
    if (!host) return { unmount() {}, refresh() {} };

    host.innerHTML =
      '<div data-role="rec-flows" style="display:flex;flex-direction:column;gap:4px;font-size:11px"></div>' +
      '<div data-role="rec-status" style="margin-top:6px;font-size:10px;color:#64748b"></div>';

    const flowsEl  = host.querySelector('[data-role="rec-flows"]');
    const statusEl = host.querySelector('[data-role="rec-status"]');

    async function refresh() {
      const sid = getSessionId ? getSessionId() : '';
      if (!sid) {
        flowsEl.innerHTML = '<div style="color:#94a3b8">Pick a session to see flows.</div>';
        return;
      }
      const flows = await listFlows(sid);
      if (!flows.length) {
        flowsEl.innerHTML = '<div style="color:#94a3b8">No saved flows yet. Hit Record to capture one.</div>';
        return;
      }
      flowsEl.innerHTML = flows.map((f) =>
        '<div data-flow-id="' + escapeHTML(f.id) + '" style="display:flex;align-items:center;gap:6px;padding:4px 6px;background:rgba(15,23,42,0.04);border-radius:4px">' +
          '<span style="flex:1;color:#0f172a;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">' + escapeHTML(f.name) + '</span>' +
          '<span style="color:#64748b;font-size:10px">' + (f.steps?.length || 0) + ' steps</span>' +
          '<button data-act="replay" style="font-size:10px;padding:2px 6px">Replay</button>' +
        '</div>'
      ).join('');
      flowsEl.querySelectorAll('[data-act="replay"]').forEach((btn) => {
        btn.onclick = async () => {
          const row = btn.closest('[data-flow-id]');
          const flowId = row?.dataset.flowId;
          const udid = getUdid ? getUdid() : '';
          if (!flowId || !udid) {
            statusEl.textContent = 'Replay needs a focused simulator.';
            return;
          }
          btn.disabled = true;
          statusEl.textContent = `Replaying ${flowId.slice(0, 8)}…`;
          try {
            const r = await replay({ sessionId: getSessionId(), flowId, udid });
            statusEl.textContent = `Replayed ${r.executed} step(s) ${r.ok ? 'OK' : '— last step failed'}.`;
          } catch (e) {
            statusEl.textContent = 'Replay failed: ' + (e.message || 'error').slice(0, 80);
          } finally {
            btn.disabled = false;
          }
        };
      });
    }

    window.addEventListener('baguette:session-change', refresh);
    refresh();

    return {
      unmount() {
        window.removeEventListener('baguette:session-change', refresh);
        host.innerHTML = '';
      },
      refresh,
    };
  }

  window.BaguetteFlowRecorder = {
    get isRecording() { return state.active; },
    start,
    stop,
    mount,
    listFlows,
    replay,
  };
})();
