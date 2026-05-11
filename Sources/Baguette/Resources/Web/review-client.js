// review-client.js — orchestrator that mounts the Activity Monitor
// dock + Selection dock on top of the live simulator view (single
// device + /farm focus). Replaces the previous floating "Review Mode"
// widget. The Select toggle in the Activity header flips the
// underlying AXInspector into select-mode.
//
// Public API:
//   BaguetteReviewClient.install({ getUdid, getInspector })
//     — mount on /simulators/:udid. getInspector returns the
//       AXInspector instance created by sim-stream.js.
//
//   BaguetteReviewClient.attachToFocus({ host, getUdid, getInspector })
//     — mount on a /farm focused tile. `host` is the focused-tile
//       container; we inject docks into it without disturbing the
//       canvas re-parent. Returns { unmount }.

(function () {
  'use strict';

  const SESSION_KEY = 'baguette.review.session';
  const SESSION_CHANGE_EVENT = 'baguette:session-change';

  function getSessionId() {
    return localStorage.getItem(SESSION_KEY) || '';
  }

  // Update the active session id everywhere — writes localStorage
  // and dispatches a window CustomEvent so dock subscribers (the
  // selection composer + Activity dock + Tasks panel) re-bind without
  // a page reload. Pass an empty string to clear.
  function setSessionId(id) {
    const prev = getSessionId();
    const next = id || '';
    if (next === prev) return;
    if (next) localStorage.setItem(SESSION_KEY, next);
    else localStorage.removeItem(SESSION_KEY);
    try {
      window.dispatchEvent(new CustomEvent(SESSION_CHANGE_EVENT, { detail: { id: next, previous: prev } }));
    } catch (_) { /* ignore */ }
  }

  async function ensureSession() {
    let id = getSessionId();
    if (id) return id;
    const name = (typeof location !== 'undefined' ? 'Live session · ' + new Date().toLocaleString() : 'Live session');
    const session = await createSession(name);
    return session.id;
  }

  // POST /reviews — returns the full session object. Caller is
  // responsible for committing the id via setSessionId() if it wants
  // to make the new session active.
  async function createSession(name) {
    const res = await fetch('/reviews', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ name }),
    });
    if (!res.ok) throw new Error(await res.text());
    const session = await res.json();
    if (!session || !session.id) throw new Error('session response missing id');
    setSessionId(session.id);
    return session;
  }

  async function listSessions() {
    const res = await fetch('/reviews.json');
    if (!res.ok) throw new Error('reviews list failed: ' + res.status);
    const arr = await res.json();
    return Array.isArray(arr) ? arr : [];
  }

  // --- single-device install (page-level docks) ---------------------

  let pageState = null;

  // Inject a session picker into the sim's top toolbar (sim-native
  // mode). Falls back gracefully when the toolbar slot isn't present.
  // Re-renders the option list on every focus + on session-change
  // events so a "+ New" creation from elsewhere stays in sync.
  async function injectSessionPicker(slot) {
    if (!slot) return;
    if (slot.querySelector('[data-role="bag-session-picker"]')) return; // idempotent

    const wrap = document.createElement('label');
    wrap.dataset.role = 'bag-session-picker-wrap';
    wrap.style.cssText =
      'display:inline-flex;align-items:center;gap:6px;font-size:11px;color:#1f2937;' +
      'background:#fff;border:1px solid #d8dee8;border-radius:999px;padding:3px 6px 3px 10px';
    wrap.title = 'Active review session — comments + tasks land here. Switch any time.';
    wrap.innerHTML =
      '<span style="font-size:10px;letter-spacing:0.3px;text-transform:uppercase;color:#64748b">Session</span>' +
      '<select data-role="bag-session-picker"' +
        ' style="border:0;background:transparent;font-size:11px;font-weight:500;color:#0f172a;outline:none;cursor:pointer;max-width:160px"></select>';
    slot.appendChild(wrap);

    const select = wrap.querySelector('select');

    async function refresh() {
      let sessions = [];
      try { sessions = await listSessions(); } catch (_) { sessions = []; }
      const activeId = getSessionId();
      const knownIds = new Set(sessions.map((s) => s.id));
      // If localStorage points at a session that no longer exists,
      // drop the stale id so the picker self-heals.
      if (activeId && !knownIds.has(activeId)) setSessionId('');

      const opts = sessions.map((s) =>
        '<option value="' + s.id + '"' + (s.id === getSessionId() ? ' selected' : '') + '>' +
          escapeHTML(s.name || '(unnamed)') +
        '</option>'
      );
      // Always offer "+ New" as the final option.
      opts.push('<option value="__new__">+ New session…</option>');
      // And an empty state if there's no active session.
      if (!getSessionId()) {
        opts.unshift('<option value="" selected disabled hidden>Pick a session…</option>');
      }
      select.innerHTML = opts.join('');
    }

    select.addEventListener('change', async () => {
      const v = select.value;
      if (v === '__new__') {
        const name = prompt('New review session name', 'Review · ' + new Date().toLocaleString());
        if (!name) { await refresh(); return; }
        try {
          await createSession(name);   // also sets it active via setSessionId
        } catch (e) {
          alert('Create failed: ' + (e && e.message ? e.message.slice(0, 200) : 'error'));
        }
        await refresh();
        return;
      }
      setSessionId(v);
    });

    window.addEventListener(SESSION_CHANGE_EVENT, refresh);
    await refresh();
  }

  function escapeHTML(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    })[c]);
  }

  function installPage(opts) {
    if (pageState) return; // idempotent
    const getUdid = (opts && opts.getUdid) || (() => null);
    const getInspector = (opts && opts.getInspector) || (() => null);

    // Activity dock — slides in from the right when queue-mode is
    // toggled. NOT permanently mounted; the simulator keeps the full
    // viewport until the user opts in.
    const activityHost = document.createElement('div');
    activityHost.id = 'baguette-activity-dock';
    activityHost.style.cssText =
      'position:fixed;top:0;right:0;width:300px;height:100vh;' +
      'z-index:60;background:#fff;box-shadow:-1px 0 0 #e2e8f0;' +
      'transform:translateX(100%);transition:transform 180ms ease-out;' +
      'pointer-events:none';
    document.body.appendChild(activityHost);

    const activity = window.SimActivity && window.SimActivity.mount({
      host: activityHost,
      getSession: () => ensureSession(),
    });
    // The toolbar icon is the canonical control; hide the dock's
    // internal Select checkbox to avoid two competing toggles.
    if (activity && activity.hideSelectToggle) activity.hideSelectToggle();
    if (activity) {
      const sid = getSessionId();
      if (sid) activity.setSession(sid);
    }

    // Selection dock — slides up from the bottom alongside the
    // activity sheet. Holds the chip strip + comment composer.
    const selectionHost = document.createElement('div');
    selectionHost.id = 'baguette-selection-dock';
    selectionHost.style.cssText =
      'position:fixed;left:14px;right:314px;bottom:14px;z-index:55;' +
      'background:#fff;border:1px solid #d8dee8;border-radius:10px;' +
      'box-shadow:0 8px 24px rgba(15,23,42,.18);padding:10px 12px;' +
      'font:12px -apple-system,BlinkMacSystemFont,SF Pro Text,sans-serif;' +
      'transform:translateY(150%);transition:transform 180ms ease-out;' +
      'pointer-events:none';
    document.body.appendChild(selectionHost);

    const selection = window.SimSelectionDock && window.SimSelectionDock.mount({
      host: selectionHost,
      getInspector,
      getSession: () => ensureSession(),
      getUdid,
    });

    pageState = {
      activityHost, selectionHost, activity, selection,
      getInspector,
      open: false,
    };

    // Inject the session picker into the sim-native top toolbar.
    // .tb-controls is the right-side group that already hosts the
    // format picker, rotation, AX inspector, queue toggle, etc. The
    // toolbar template loads AFTER this install fires, so we poll
    // briefly until it appears.
    (function attachPicker(retries) {
      const slot = document.querySelector('.tb-controls');
      if (slot) { injectSessionPicker(slot); return; }
      if (retries <= 0) return;
      setTimeout(() => attachPicker(retries - 1), 200);
    })(50);

    // Re-bind Activity dock subscription on session changes.
    window.addEventListener(SESSION_CHANGE_EVENT, (e) => {
      if (activity && activity.setSession) activity.setSession(e.detail && e.detail.id || '');
    });
  }

  // Public toggle — driven by the focus-mode toolbar `nativeQueueToggle`
  // icon (and re-usable for any sibling host). Slides docks in/out
  // and flips the AX overlay between gesture-passthrough and
  // multi-select capture.
  function toggleQueueMode(on) {
    if (!pageState) return;
    const want = (on === undefined) ? !pageState.open : !!on;
    pageState.open = want;
    const ins = pageState.getInspector ? pageState.getInspector() : null;
    if (want) {
      if (ins) {
        if (!ins.isEnabled()) ins.enable();
        ins.setSelectionMode('select');
      }
      pageState.activityHost.style.transform = 'translateX(0)';
      pageState.activityHost.style.pointerEvents = 'auto';
      pageState.selectionHost.style.transform = 'translateY(0)';
      pageState.selectionHost.style.pointerEvents = 'auto';
    } else {
      if (ins) ins.disable();
      pageState.activityHost.style.transform = 'translateX(100%)';
      pageState.activityHost.style.pointerEvents = 'none';
      pageState.selectionHost.style.transform = 'translateY(150%)';
      pageState.selectionHost.style.pointerEvents = 'none';
    }
  }

  // --- farm-focus attach (tile-scoped docks) ------------------------

  function attachToFocus(opts) {
    const host = opts && opts.host;
    const getUdid = (opts && opts.getUdid) || (() => null);
    const getInspector = (opts && opts.getInspector) || (() => null);
    if (!host) return { unmount() {} };

    // Locate the slots the focused-tile chrome already exposes inside
    // the Review Mapping sidebar section (farm-focus.js). If they
    // aren't there yet, poll briefly — focus.show() builds them in
    // the same tick FarmApp calls us, but order isn't guaranteed.
    let activityHost   = host.querySelector('[data-role="activity-host"]');
    let selectionHost  = host.querySelector('[data-role="selection-host"]');
    let recorderHost   = host.querySelector('[data-role="recorder-host"]');
    let pickerSlot     = host.querySelector('[data-role="session-picker-slot"]');
    let activityPane   = host.querySelector('[data-role="review-activity-pane"]');
    let selectionPane  = host.querySelector('[data-role="review-selection-pane"]');
    let recorderPane   = host.querySelector('[data-role="review-recorder-pane"]');

    const activity = activityHost && window.SimActivity && window.SimActivity.mount({
      host: activityHost,
      getSession: () => ensureSession(),
    });
    if (activity && activity.hideSelectToggle) activity.hideSelectToggle();
    if (activity) {
      const sid = getSessionId();
      if (sid) activity.setSession(sid);
    }
    window.addEventListener(SESSION_CHANGE_EVENT, (e) => {
      if (activity && activity.setSession) activity.setSession((e.detail && e.detail.id) || '');
    });

    const selection = selectionHost && window.SimSelectionDock && window.SimSelectionDock.mount({
      host: selectionHost,
      getInspector,
      getSession: () => ensureSession(),
      getUdid,
    });

    // Wire the inline "Select elements" preset button to the same
    // toggle behaviour as the page-mode toolbar icon.
    const selectBtn = host.querySelector('[data-action="review-select"]');
    if (selectBtn) {
      let on = false;
      selectBtn.addEventListener('click', () => {
        on = !on;
        selectBtn.classList.toggle('active', on);
        selectBtn.textContent = on ? 'Selecting…' : 'Select elements';
        const ins = getInspector();
        if (!ins) return;
        if (on) {
          if (!ins.isEnabled()) ins.enable();
          ins.setSelectionMode('select');
          if (selectionPane) selectionPane.open = true;
          if (activityPane)  activityPane.open  = true;
        } else {
          ins.disable();
        }
      });
    }

    // Mount the session picker into the Review Mapping header slot.
    if (pickerSlot) injectSessionPicker(pickerSlot);

    // Mount the saved-flows list + replay buttons.
    const recorder = recorderHost && window.BaguetteFlowRecorder && window.BaguetteFlowRecorder.mount({
      host: recorderHost,
      getSessionId,
      getUdid,
    });

    // Wire the Record toggle. Recording starts a session-scoped
    // capture; Stop POSTs the steps to the server and re-renders the
    // dock's flow list.
    const recordBtn = host.querySelector('[data-action="review-record"]');
    if (recordBtn && window.BaguetteFlowRecorder) {
      let isRecording = false;
      recordBtn.addEventListener('click', async () => {
        const sid = getSessionId() || (await ensureSession());
        if (!sid) {
          alert('Pick or create a review session first.');
          return;
        }
        if (!isRecording) {
          window.BaguetteFlowRecorder.start({ sessionId: sid });
          isRecording = true;
          recordBtn.classList.add('active');
          recordBtn.textContent = 'Stop recording';
          if (recorderPane) recorderPane.open = true;
        } else {
          isRecording = false;
          recordBtn.classList.remove('active');
          recordBtn.textContent = 'Record';
          const name = prompt('Flow name', 'Flow · ' + new Date().toLocaleTimeString());
          if (name === null) {
            // user cancelled — discard
            await window.BaguetteFlowRecorder.stop({});
            return;
          }
          await window.BaguetteFlowRecorder.stop({ name });
          if (recorder && recorder.refresh) recorder.refresh();
        }
      });
    }

    return {
      unmount() {
        if (selection) selection.unmount();
        if (activity)  activity.unmount();
        if (recorder)  recorder.unmount();
        if (activityHost)  activityHost.innerHTML  = '';
        if (selectionHost) selectionHost.innerHTML = '';
        if (recorderHost)  recorderHost.innerHTML  = '';
      },
    };
  }

  window.BaguetteReviewClient = {
    install: installPage,
    attachToFocus,
    toggleQueueMode,
    ensureSession,
    getSessionId,
  };
})();
