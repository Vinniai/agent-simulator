(function () {
  'use strict';

  const state = {
    sessions: [],
    session: null,
    selected: null,
    selectedIds: new Set(),
    axCache: new Map(),
    axTreeCache: new Map(),  // parsed JSON + path-stamped
    tasks: [],
    activeAxTree: null,      // ReviewAxTree mount handle
    selectedAxPath: null,    // chosen via tree click or comment click
  };

  document.addEventListener('DOMContentLoaded', boot);

  async function boot() {
    byId('new-review').onclick = newReview;
    byId('bundle-selected').onclick = bundleSelected;
    byId('save-comment').onclick = saveComment;
    byId('queue-task').onclick = queueTask;
    const collapseBtn = byId('tasks-collapse');
    if (collapseBtn) {
      collapseBtn.onclick = () => {
        const list = byId('tasks-list');
        const collapsed = list.style.display === 'none';
        list.style.display = collapsed ? '' : 'none';
        collapseBtn.textContent = collapsed ? '▾' : '▸';
      };
    }
    await loadSessions();
    const id = location.pathname.split('/')[2];
    if (id) await loadSession(id);
  }

  async function loadSessions() {
    const res = await fetch('/reviews.json');
    state.sessions = await res.json();
    renderSessions();
  }

  async function loadSession(id) {
    const res = await fetch(`/reviews/${encodeURIComponent(id)}/manifest.json`);
    state.session = await res.json();
    state.selected = null;
    state.selectedIds.clear();
    byId('review-title').textContent = state.session.name;
    renderSessions();
    renderCanvas();
    renderInspector();
    loadTasks(id);
    if (window.ReviewCompare && typeof window.ReviewCompare.setSession === 'function') {
      window.ReviewCompare.setSession(state.session);
    }
  }

  let tasksStream = null;
  function loadTasks(sessionId) {
    state.tasks = [];
    renderTasks();
    if (!sessionId) return;
    if (!tasksStream) {
      if (!window.ReviewTasksStream) return; // helper not loaded
      tasksStream = window.ReviewTasksStream.subscribe({
        sessionId,
        onSnapshot: (tasks) => {
          state.tasks = tasks || [];
          renderTasks();
          maybeFocusFromQuery();
        },
        onTaskUpdate: (task) => {
          if (!task || !task.id) return;
          const i = state.tasks.findIndex((t) => t.id === task.id);
          if (i >= 0) state.tasks[i] = task;
          else state.tasks.push(task);
          renderTasks();
        },
        onStatus: () => {},
        onError:  () => {},
      });
    } else {
      tasksStream.setSession(sessionId);
    }
  }

  // If the URL carries ?task=<taskId> (deep-link from the Activity
  // dock), auto-select the task's first snapshot so the operator
  // lands on the right tile + sees comments / elements without
  // hunting through the map.
  function maybeFocusFromQuery() {
    const params = new URLSearchParams(location.search);
    const taskId = params.get('task');
    if (!taskId || !state.session) return;
    const t = state.tasks.find((x) => x.id === taskId);
    if (!t || !t.elements || !t.elements[0]) return;
    const sid = t.elements[0].snapshotId;
    const snap = state.session.snapshots.find((s) => s.id === sid);
    if (snap) {
      state.selected = snap;
      state.selectedIds = new Set([snap.id]);
      renderCanvas();
      renderInspector();
    }
    // Drop the query param so subsequent clicks don't keep re-focusing.
    history.replaceState(null, '', `/reviews/${encodeURIComponent(state.session.id)}`);
  }

  // Shared with sim-activity.js so the Tasks panel and the Activity
  // dock read as the same control across /reviews and /simulators.
  const STATUS_PILL = {
    open:           { bg: '#e2e8f0', fg: '#1e293b', label: 'open'        },
    claimed:        { bg: '#fde68a', fg: '#854d0e', label: 'claimed'     },
    inProgress:     { bg: '#fde68a', fg: '#854d0e', label: 'in progress' },
    readyForVerify: { bg: '#dbeafe', fg: '#1e3a8a', label: 'verify'      },
    verified:       { bg: '#dcfce7', fg: '#166534', label: 'verified'    },
    failed:         { bg: '#fee2e2', fg: '#991b1b', label: 'failed'      },
  };

  function timeAgo(iso) {
    if (!iso) return '';
    const ms = Date.now() - new Date(iso).getTime();
    if (!Number.isFinite(ms) || ms < 0) return '';
    const m = Math.round(ms / 60000);
    if (m < 1) return 'just now';
    if (m < 60) return m + 'm';
    const h = Math.round(m / 60);
    if (h < 24) return h + 'h';
    return Math.round(h / 24) + 'd';
  }

  function renderTasks() {
    const panel = byId('tasks-panel');
    const list = byId('tasks-list');
    const count = byId('tasks-count');
    if (!panel || !list) return;
    const tasks = state.tasks || [];
    if (!tasks.length) {
      panel.style.display = 'none';
      return;
    }
    panel.style.display = '';
    count.textContent = '(' + tasks.length + ')';

    list.innerHTML = tasks.map((t) => {
      const pill = STATUS_PILL[t.status] || { bg: '#e2e8f0', fg: '#1e293b', label: t.status || '?' };
      const cc = (t.elements || []).filter((e) => e && e.commentText && e.commentText.trim()).length;
      const elsHTML = (t.elements || []).map((e) => {
        const label = (e.role || '') + (e.label ? (' · ' + e.label) : '');
        return `<span style="display:inline-block;background:#fef3c7;color:#92400e;padding:1px 6px;border-radius:4px;margin:3px 4px 0 0;font-size:10px;font-family:ui-monospace" data-path="${esc(e.axNodePath)}" title="${esc(e.axNodePath)}">${esc(label)}</span>`;
      }).join('');
      const commentNotes = (t.elements || [])
        .filter((e) => e.commentText)
        .map((e) => `<span style="display:inline-block;background:#f1f5f9;color:#0f172a;padding:1px 6px;border-radius:4px;margin:3px 4px 0 0;font-size:11px" title="${esc(e.axNodePath)}">${esc(e.commentText.slice(0,80))}</span>`)
        .join('');
      const ageStr = timeAgo(t.updatedAt || t.createdAt);
      return `<div data-task-id="${esc(t.id)}" data-snap-id="${esc((t.elements&&t.elements[0]&&t.elements[0].snapshotId)||'')}" style="padding:10px;background:#fff;border:1px solid #e2e8f0;border-radius:8px;margin-bottom:6px;cursor:pointer;transition:background 80ms">
        <div style="display:flex;gap:6px;align-items:center;margin-bottom:4px">
          <span style="background:${pill.bg};color:${pill.fg};padding:1px 7px;border-radius:999px;font-size:10px;font-weight:600;text-transform:uppercase;letter-spacing:0.3px">${esc(pill.label)}</span>
          ${cc ? `<span style="font-size:10px;color:#64748b" title="${cc} comment(s)">💬 ${cc}</span>` : ''}
          <strong style="flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:12px">${esc(t.title||'(untitled)')}</strong>
          <span style="color:#94a3b8;font-size:10px;font-variant-numeric:tabular-nums">${esc(ageStr)}</span>
        </div>
        ${elsHTML ? `<div>${elsHTML}</div>` : ''}
        ${commentNotes ? `<div>${commentNotes}</div>` : ''}
      </div>`;
    }).join('');
    list.querySelectorAll('[data-task-id]').forEach((row) => {
      row.addEventListener('click', () => {
        const sid = row.dataset.snapId;
        if (!sid) return;
        const snap = state.session.snapshots.find((x) => x.id === sid);
        if (!snap) return;
        state.selected = snap;
        state.selectedIds = new Set([snap.id]);
        renderCanvas();
        renderInspector();
      });
    });
  }

  async function newReview() {
    const name = prompt('Review name', 'App review');
    const res = await fetch('/reviews', {
      method:'POST',
      headers:{'content-type':'application/json'},
      body:JSON.stringify({ name: name || 'App review' })
    });
    const session = await res.json();
    history.replaceState(null, '', `/reviews/${encodeURIComponent(session.id)}`);
    await loadSessions();
    await loadSession(session.id);
  }

  function renderSessions() {
    const host = byId('session-list');
    host.innerHTML = state.sessions.map(s => `
      <button class="session ${state.session && state.session.id === s.id ? 'active' : ''}" data-id="${esc(s.id)}">
        <strong>${esc(s.name)}</strong><br>
        <span>${s.snapshots.length} screens · ${new Date(s.createdAt).toLocaleString()}</span>
      </button>
    `).join('');
    host.querySelectorAll('[data-id]').forEach(btn => {
      btn.onclick = () => {
        history.replaceState(null, '', `/reviews/${encodeURIComponent(btn.dataset.id)}`);
        loadSession(btn.dataset.id);
      };
    });
  }

  function renderCanvas() {
    const host = byId('canvas');
    const s = state.session;
    if (!s) { host.innerHTML = ''; return; }
    const positions = new Map();
    const cols = 4;
    s.snapshots.forEach((snap, i) => {
      const x = 80 + (i % cols) * 320;
      const y = 80 + Math.floor(i / cols) * 520;
      positions.set(snap.id, { x, y });
    });
    const edges = s.edges.map(e => {
      const a = e.fromSnapshotId && positions.get(e.fromSnapshotId);
      const b = positions.get(e.toSnapshotId);
      if (!a || !b) return '';
      const x1 = a.x + 220, y1 = a.y + 210, x2 = b.x, y2 = b.y + 210;
      const dx = x2 - x1, dy = y2 - y1;
      const len = Math.max(1, Math.sqrt(dx * dx + dy * dy));
      const angle = Math.atan2(dy, dx) * 180 / Math.PI;
      return `<div class="edge" style="left:${x1}px;top:${y1}px;width:${len}px;transform:rotate(${angle}deg)"><span>${esc(e.actionType)}</span></div>`;
    }).join('');
    const nodes = s.snapshots.map((snap) => {
      const p = positions.get(snap.id);
      const badges = snap.markers.map(m => `<span class="badge ${esc(m.kind)}">${esc(m.kind)}</span>`).join('');
      return `<article class="node ${state.selected && state.selected.id === snap.id ? 'selected' : ''}"
          data-id="${esc(snap.id)}" style="left:${p.x}px;top:${p.y}px">
        <img src="${artifactURL(snap.screenshotPath)}" alt="">
        <div class="node-meta">
          ${badges}
          <div>${esc(snap.id)}</div>
          <div>${new Date(snap.timestamp).toLocaleTimeString()}</div>
        </div>
      </article>`;
    }).join('');
    host.innerHTML = edges + nodes;
    host.querySelectorAll('.node').forEach(n => {
      n.onclick = (e) => {
        const snap = s.snapshots.find(x => x.id === n.dataset.id);
        state.selected = snap;
        if (e.metaKey || e.ctrlKey) {
          if (state.selectedIds.has(snap.id)) state.selectedIds.delete(snap.id);
          else state.selectedIds.add(snap.id);
        } else {
          state.selectedIds = new Set([snap.id]);
        }
        byId('bundle-selected').disabled = state.selectedIds.size === 0;
        renderCanvas();
        renderInspector();
      };
    });
  }

  async function renderInspector() {
    const snap = state.selected;
    byId('inspector-empty').hidden = !!snap;
    byId('inspector').hidden = !snap;
    if (!snap || !state.session) return;
    state.selectedAxPath = null;
    byId('shot').src = artifactURL(snap.screenshotPath);
    byId('meta').innerHTML = `
      <div>snapshot: ${esc(snap.id)}</div>
      <div>udid: ${esc(snap.udid)}</div>
      <div>fingerprint: ${esc(snap.screenFingerprint)}</div>
    `;
    byId('comment-path').value = '';
    byId('comment-text').value = '';

    // Resolve + cache the parsed AX tree once per snapshot.
    let parsedTree = state.axTreeCache.get(snap.id);
    if (!parsedTree) {
      try {
        const res = await fetch(artifactURL(snap.axPath));
        const text = await res.text();
        parsedTree = JSON.parse(text);
        if (window.AxTreeHelpers) window.AxTreeHelpers.stampPaths(parsedTree);
        state.axTreeCache.set(snap.id, parsedTree);
        state.axCache.set(snap.id, text);   // legacy callers
      } catch (_) {
        parsedTree = null;
      }
    }

    renderCommentList();

    // Mount the interactive tree component.
    if (state.activeAxTree && state.activeAxTree.unmount) state.activeAxTree.unmount();
    if (window.ReviewAxTree) {
      state.activeAxTree = window.ReviewAxTree.mount({
        host: byId('ax-tree'),
        tree: parsedTree,
        comments: (state.session.comments || []).filter((c) => c.snapshotId === snap.id),
        onSelect: (node) => {
          state.selectedAxPath = node && node._path || null;
          renderCommentList();
          // Mirror the path into the comment composer so saving picks it up.
          byId('comment-path').value = state.selectedAxPath || '';
        },
        onHover: () => { /* reserved for bbox overlay in Phase 3 */ },
      });
    }
  }

  // Render comments list filtered by selectedAxPath when set.
  function renderCommentList() {
    const snap = state.selected;
    if (!snap || !state.session) return;
    const all = state.session.comments.filter((c) => c.snapshotId === snap.id);
    const filtered = state.selectedAxPath
      ? all.filter((c) => c.axNodePath === state.selectedAxPath)
      : all;
    const parsedTree = state.axTreeCache.get(snap.id);
    byId('comment-list').innerHTML = filtered.length
      ? filtered.map((c) => commentRowHTML(c, parsedTree)).join('')
      : (state.selectedAxPath
          ? `<div class="meta">No comments on this element. <a href="#" data-act="clear-filter">show all (${all.length})</a></div>`
          : '<div class="meta">No comments yet.</div>');
    const clear = byId('comment-list').querySelector('[data-act="clear-filter"]');
    if (clear) clear.onclick = (e) => { e.preventDefault(); state.selectedAxPath = null; if (state.activeAxTree) state.activeAxTree.setSelectedPath(null); renderCommentList(); byId('comment-path').value = ''; };
    byId('comment-list').querySelectorAll('[data-comment-path]').forEach((el) => {
      el.onclick = () => {
        const p = el.dataset.commentPath;
        state.selectedAxPath = p;
        if (state.activeAxTree) state.activeAxTree.setSelectedPath(p);
        byId('comment-path').value = p;
        renderCommentList();
      };
    });
  }

  function commentRowHTML(c, parsedTree) {
    const node = parsedTree && window.AxTreeHelpers ? window.AxTreeHelpers.findByPath(parsedTree, c.axNodePath) : null;
    const role = (node && node.role) || '';
    const label = (node && (node.label || node.identifier || node.title || node.value)) || '';
    const head = role || label
      ? `<span style="color:#2563eb">[${esc(role)}]</span>${label ? ' <span>"' + esc(label) + '"</span>' : ''}`
      : '<span style="color:#94a3b8;font-style:italic">unresolved element</span>';
    return `<div class="comment" data-comment-path="${esc(c.axNodePath)}" style="cursor:pointer">
      <div class="path" style="display:flex;gap:6px;align-items:baseline;font-family:-apple-system,BlinkMacSystemFont,SF Pro Text,sans-serif;font-size:11px">
        ${head}
        <span style="color:#94a3b8;font-family:ui-monospace;font-size:10px;margin-left:auto" title="${esc(c.axNodePath)}">${esc(c.axNodePath)}</span>
      </div>
      <div>${esc(c.text)}</div>
    </div>`;
  }

  async function saveComment() {
    if (!state.session || !state.selected) return;
    const text = byId('comment-text').value.trim();
    if (!text) return;
    await fetch(`/reviews/${encodeURIComponent(state.session.id)}/comments`, {
      method:'POST',
      headers:{'content-type':'application/json'},
      body:JSON.stringify({
        snapshotId: state.selected.id,
        axNodePath: byId('comment-path').value.trim() || '/',
        text,
        status:'open'
      })
    });
    await loadSession(state.session.id);
  }

  async function queueTask() {
    if (!state.session || !state.selected) return;
    const axPath = byId('comment-path').value.trim();
    if (!axPath) {
      alert('Enter the AX node path of the element this task should target.');
      return;
    }
    const instructions = prompt('What should the agent do with this element?');
    if (!instructions) return;
    const res = await fetch(`/reviews/${encodeURIComponent(state.session.id)}/tasks`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        instructions,
        snapshotIds: [state.selected.id],
        elements: [{ snapshotId: state.selected.id, axNodePath: axPath }],
      }),
    });
    if (!res.ok) {
      alert(`Queue failed: ${await res.text()}`);
      return;
    }
    const task = await res.json();
    alert(`Queued ${task.id}`);
    await loadSession(state.session.id);
  }

  async function bundleSelected() {
    if (!state.session || state.selectedIds.size === 0) return;
    const res = await fetch(`/reviews/${encodeURIComponent(state.session.id)}/bundles`, {
      method:'POST',
      headers:{'content-type':'application/json'},
      body:JSON.stringify({ snapshotIds:[...state.selectedIds] })
    });
    const bundle = await res.json();
    const summary = `Review bundle: ${state.session.name}\n${location.origin}/reviews/${state.session.id}\nBrief: ${location.origin}${artifactURL(bundle.markdownPath)}`;
    showBundleResult(bundle, summary);
    await loadSession(state.session.id);
  }

  function showBundleResult(bundle, summary) {
    const panel = byId('bundle-result');
    if (!panel) return;
    panel.style.display = '';
    panel.innerHTML =
      '<div style="display:flex;align-items:center;gap:6px;margin-bottom:6px">' +
        '<strong style="font-size:12px">Evidence bundle</strong>' +
        '<span style="color:#94a3b8;font-size:10px">' + esc(bundle.id.slice(-6)) + '</span>' +
        '<button data-act="close" style="margin-left:auto;background:transparent;border:0;cursor:pointer;color:#94a3b8;font-size:14px">×</button>' +
      '</div>' +
      '<div style="font-size:11px;line-height:1.5">' +
        '<a href="' + artifactURL(bundle.markdownPath) + '" target="_blank" rel="noopener"' +
        ' style="display:inline-block;margin-right:8px;color:#1d4ed8">📄 Brief (Markdown)</a>' +
        '<a href="' + artifactURL(bundle.jsonPath) + '" target="_blank" rel="noopener"' +
        ' style="color:#1d4ed8">{ } JSON</a>' +
      '</div>' +
      '<button data-act="copy"' +
        ' style="margin-top:8px;background:#0f172a;color:#fff;border:0;border-radius:6px;padding:5px 10px;cursor:pointer;font-size:11px">' +
        'Copy summary to clipboard' +
      '</button>';
    panel.querySelector('[data-act="close"]').onclick = () => { panel.style.display = 'none'; };
    panel.querySelector('[data-act="copy"]').onclick = async () => {
      try {
        await navigator.clipboard?.writeText(summary);
        panel.querySelector('[data-act="copy"]').textContent = 'Copied ✓';
        setTimeout(() => { const b = panel.querySelector('[data-act="copy"]'); if (b) b.textContent = 'Copy summary to clipboard'; }, 1500);
      } catch (_) {}
    };
  }

  function artifactURL(path) {
    return `/reviews/${encodeURIComponent(state.session.id)}/artifact?path=${encodeURIComponent(path)}`;
  }
  function byId(id) { return document.getElementById(id); }
  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
})();

