// sim-selection-dock.js — bottom strip that pairs with AXInspector's
// select-mode. Subscribes to onSelectionChange, renders a chip per
// element, exposes a comment composer + "Queue task" button that
// POSTs /reviews/:sessionId/tasks with all selected elements in a
// single multi-element task.
//
// Public API:
//   SimSelectionDock.mount({ host, getInspector, getSession, getUdid })
//     → returns { unmount, refresh }
//
//   - host:          parent element to render into (chip strip + composer)
//   - getInspector:  () => AXInspector instance (must support onSelectionChange)
//   - getSession:    () => Promise<sessionId>  — ensures/creates a review session
//   - getUdid:       () => string | null       — current UDID

(function () {
  'use strict';

  function escapeHTML(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
    })[c]);
  }

  function chipLabel(node) {
    if (!node) return 'unknown';
    const role = node.role ? '[' + node.role + '] ' : '';
    const text = node.label || node.identifier || node.title || node.value || '(unlabeled)';
    return role + text;
  }

  function mount(opts) {
    const host       = opts.host;
    const getIns     = opts.getInspector;
    const getSession = opts.getSession;
    const getUdid    = opts.getUdid;
    if (!host || !getIns || !getSession || !getUdid) return { unmount(){}, refresh(){} };

    host.innerHTML =
      '<div data-role="chips" style="display:flex;flex-wrap:wrap;gap:6px;padding:6px 0;min-height:0"></div>' +
      '<div data-role="composer" style="display:none;flex-direction:row;gap:6px;align-items:flex-start;padding-top:6px;border-top:1px solid #e2e8f0">' +
        '<textarea data-role="text" rows="2" placeholder="Leave a note for the agent…"' +
          ' style="flex:1;resize:none;font:12px -apple-system,BlinkMacSystemFont,SF Pro Text,sans-serif;' +
          'padding:6px 8px;border:1px solid #d8dee8;border-radius:6px;outline:none;background:#fff"></textarea>' +
        '<button data-role="queue" disabled' +
          ' style="padding:0 12px;height:44px;background:#0f172a;color:#fff;border:0;border-radius:8px;cursor:pointer;font-size:12px;font-weight:600">' +
          'Queue task' +
        '</button>' +
      '</div>' +
      '<div data-role="toast" style="display:none;margin-top:6px;font-size:11px;color:#0f5132"></div>';

    const chipsEl    = host.querySelector('[data-role="chips"]');
    const composerEl = host.querySelector('[data-role="composer"]');
    const textEl     = host.querySelector('[data-role="text"]');
    const queueEl    = host.querySelector('[data-role="queue"]');
    const toastEl    = host.querySelector('[data-role="toast"]');

    let currentSelections = [];
    let queueing = false;

    function setQueueEnabled(on) {
      queueEl.disabled = !on;
      queueEl.style.opacity = on ? '1' : '0.5';
      queueEl.style.cursor  = on ? 'pointer' : 'not-allowed';
    }

    function renderChips() {
      if (!currentSelections.length) {
        chipsEl.innerHTML = '<span style="color:#64748b;font-size:11px;font-style:italic">No elements selected · click any box to select, shift-click to add more</span>';
        composerEl.style.display = 'none';
        setQueueEnabled(false);
        return;
      }
      composerEl.style.display = 'flex';
      chipsEl.innerHTML = currentSelections.map((s) =>
        '<span data-path="' + escapeHTML(s.path) + '"' +
          ' style="display:inline-flex;align-items:center;gap:6px;background:#e0e7ff;color:#1e293b;' +
          'padding:3px 8px 3px 10px;border-radius:999px;font-size:11px;max-width:240px">' +
          '<span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="' + escapeHTML(s.path) + '">' +
            escapeHTML(chipLabel(s.node)) +
          '</span>' +
          '<button data-act="remove" data-path="' + escapeHTML(s.path) + '"' +
            ' style="border:0;background:transparent;color:#1e293b;cursor:pointer;font-size:14px;line-height:1;padding:0 2px">×</button>' +
        '</span>'
      ).join('');
      chipsEl.querySelectorAll('[data-act="remove"]').forEach((b) => {
        b.addEventListener('click', () => {
          const ins = getIns();
          if (ins) ins.removeSelection(b.dataset.path);
        });
      });
      setQueueEnabled(textEl.value.trim().length > 0 && !queueing);
    }

    function flashToast(msg, isError) {
      toastEl.style.display = '';
      toastEl.style.color = isError ? '#991b1b' : '#0f5132';
      toastEl.textContent = msg;
      setTimeout(() => { toastEl.style.display = 'none'; toastEl.textContent = ''; }, 5000);
    }

    async function postJSON(path, body) {
      const res = await fetch(path, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (!res.ok) throw new Error(await res.text());
      return res.json();
    }

    async function doQueue() {
      const comment = textEl.value.trim();
      const udid = getUdid();
      if (!comment || !currentSelections.length || !udid) return;
      queueing = true;
      setQueueEnabled(false);
      try {
        const sessionId = await getSession();
        if (!sessionId) throw new Error('no review session');

        // Capture a fresh "before" snapshot the elements will reference.
        // The capture endpoint stores the screenshot + AX tree under the
        // session and returns the snapshot id. This is what the review
        // map page reads via snap.screenshotPath / snap.axPath.
        const capRes = await postJSON('/reviews/' + encodeURIComponent(sessionId) + '/capture', {
          udid,
          actionType: 'queue-from-overlay',
        });
        const snapshotId = capRes && capRes.snapshot && capRes.snapshot.id;
        if (!snapshotId) throw new Error('capture failed');

        // Post one comment per selected element — the review map page's
        // inspector reads session.comments[] keyed by snapshotId +
        // axNodePath, so this is what makes the comment visible when
        // the operator clicks the snapshot tile in /reviews/:id.
        //
        // The AX tree carries frames as `{x,y,width,height}` but the
        // server's `Rect` Codable expects `{origin:{x,y}, size:{width,height}}`.
        // Wrap before sending.
        const toRect = (f) => f && {
          origin: { x: f.x, y: f.y },
          size:   { width: f.width, height: f.height },
        };
        await Promise.all(currentSelections.map((s) =>
          postJSON('/reviews/' + encodeURIComponent(sessionId) + '/comments', {
            snapshotId,
            axNodePath: s.path,
            frame: s.node && toRect(s.node.frame),
            text: comment,
            status: 'open',
          }).catch(() => null)  // best-effort; task still queues if a comment fails
        ));

        // Create the multi-element task. The task's elements duplicate
        // commentText so agents working from /agent/tasks/next see the
        // intent inline; the comments collection above is the canonical
        // home for the human-readable note.
        const taskRes = await postJSON('/reviews/' + encodeURIComponent(sessionId) + '/tasks', {
          title: comment.slice(0, 60),
          instructions: comment,
          snapshotIds: [snapshotId],
          elements: currentSelections.map((s) => ({
            snapshotId,
            axNodePath: s.path,
            commentText: comment,
          })),
        });

        flashToast('Queued ' + (taskRes.id || 'task') + ' · snapshot captured · ' + currentSelections.length + ' comment(s)');
        textEl.value = '';
        const ins = getIns();
        if (ins) ins.clearSelections();
      } catch (e) {
        flashToast('Queue failed: ' + (e && e.message ? e.message.slice(0, 120) : 'error'), true);
      } finally {
        queueing = false;
        setQueueEnabled(textEl.value.trim().length > 0);
      }
    }

    queueEl.addEventListener('click', doQueue);
    textEl.addEventListener('input', () => {
      setQueueEnabled(textEl.value.trim().length > 0 && currentSelections.length > 0 && !queueing);
    });
    textEl.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        doQueue();
      }
    });

    function onSelectionChange(selections) {
      currentSelections = selections || [];
      renderChips();
    }

    // Subscribe by overriding the inspector's onSelectionChange — we
    // chain to any previously-set callback so other listeners aren't
    // stomped. In focus mode the inspector is created AFTER the
    // review client installs, so getIns() can return null at mount
    // time. Poll until it materializes, then subscribe.
    let subscribedIns = null;
    let prevHandler = null;
    let pollHandle = null;

    function trySubscribe() {
      const ins = getIns();
      if (!ins || subscribedIns === ins) return;
      subscribedIns = ins;
      prevHandler = ins.onSelectionChange;
      ins.onSelectionChange = (sels) => {
        onSelectionChange(sels);
        if (prevHandler) prevHandler(sels);
      };
      onSelectionChange(ins.getSelections ? ins.getSelections() : []);
      if (pollHandle) { clearInterval(pollHandle); pollHandle = null; }
    }

    trySubscribe();
    if (!subscribedIns) {
      pollHandle = setInterval(trySubscribe, 200);
    }
    renderChips();

    return {
      unmount() {
        if (pollHandle) { clearInterval(pollHandle); pollHandle = null; }
        if (subscribedIns && subscribedIns.onSelectionChange) {
          subscribedIns.onSelectionChange = prevHandler;
        }
        host.innerHTML = '';
      },
      refresh() {
        const i = getIns();
        if (i && i.getSelections) onSelectionChange(i.getSelections());
      },
    };
  }

  window.SimSelectionDock = { mount };
})();
