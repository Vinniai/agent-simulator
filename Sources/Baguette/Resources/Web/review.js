(function () {
  'use strict';

  const state = {
    sessions: [],
    session: null,
    selected: null,
    selectedIds: new Set(),
    axCache: new Map(),
  };

  document.addEventListener('DOMContentLoaded', boot);

  async function boot() {
    byId('new-review').onclick = newReview;
    byId('bundle-selected').onclick = bundleSelected;
    byId('save-comment').onclick = saveComment;
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
    byId('shot').src = artifactURL(snap.screenshotPath);
    byId('meta').innerHTML = `
      <div>snapshot: ${esc(snap.id)}</div>
      <div>udid: ${esc(snap.udid)}</div>
      <div>fingerprint: ${esc(snap.screenFingerprint)}</div>
    `;
    byId('comment-path').value = '';
    byId('comment-text').value = '';
    byId('comment-list').innerHTML = state.session.comments
      .filter(c => c.snapshotId === snap.id)
      .map(c => `<div class="comment"><div class="path">${esc(c.axNodePath)}</div>${esc(c.text)}</div>`)
      .join('') || '<div class="meta">No comments yet.</div>';
    let ax = state.axCache.get(snap.id);
    if (!ax) {
      const res = await fetch(artifactURL(snap.axPath));
      ax = await res.text();
      state.axCache.set(snap.id, ax);
    }
    byId('ax-tree').textContent = ax;
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

  async function bundleSelected() {
    if (!state.session || state.selectedIds.size === 0) return;
    const res = await fetch(`/reviews/${encodeURIComponent(state.session.id)}/bundles`, {
      method:'POST',
      headers:{'content-type':'application/json'},
      body:JSON.stringify({ snapshotIds:[...state.selectedIds] })
    });
    const bundle = await res.json();
    const text = `Review bundle: ${state.session.name}\n${location.origin}/reviews/${state.session.id}\nBrief: ${location.origin}${artifactURL(bundle.markdownPath)}`;
    await navigator.clipboard?.writeText(text);
    alert('Evidence bundle created and copied.');
    await loadSession(state.session.id);
  }

  function artifactURL(path) {
    return `/reviews/${encodeURIComponent(state.session.id)}/artifact?path=${encodeURIComponent(path)}`;
  }
  function byId(id) { return document.getElementById(id); }
  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
})();

