// FarmApp — boot orchestrator for /farm.
//
// One instance, owns:
//   • device discovery (GET /simulators.json on boot + manual refresh)
//   • a Map<udid, FarmTile> with one tile per booted device
//   • filter state (FarmFilter)
//   • view mode + sort + selection
//   • event wiring on the rendered DOM (delegated, so renderers
//     stay pure)
//
// Render flow on every state change:
//   1. compute visible = filter.apply(devices)
//   2. FarmViews.renderRail / renderGridHead / renderCli (chrome)
//   3. FarmViews.renderGrid|Wall|List into #farm-view-host
//   4. for each tile in visible, find its `[data-screen-host]` and
//      tile.attach(host) — the canvas hops between hosts without the
//      WebSocket noticing.
//
// Tiles for un-booted devices are NOT instantiated. Booting flips
// `uiState` to "live" and triggers a fresh tile.start() on next
// render; shutdown stops the tile.
(function () {
  'use strict';

  const VIEW_HOST_ID = 'farm-view-host';

  function wantsMobileMode() {
    const params = new URLSearchParams(location.search);
    return location.pathname === '/m' || params.get('view') === 'm';
  }

  function FarmApp() {
    this.devices = [];
    this.tiles = new Map();              // udid → FarmTile
    this.chromeLayouts = new Map();      // udid → layout|null (null = no chrome)
    this.filter = new window.FarmFilter();
    this.mobileMode = wantsMobileMode();
    this.view = this.mobileMode ? 'review' : 'grid';
    this.sort = { key: 'name', dir: 'asc' };
    this.selectedUdid = null;
    this.focus = null;
    this.showBezels = true;
    this.fleetTelemetry = { live: 0, total: 0, fps: 0, bw: 0, lat: 0 };
    this.review = {
      sessions: [],
      session: null,
      selectedSnapshotId: null,
      selectedSnapshotIds: new Set(),
      selectedElementPath: '',
      selectedElementFrame: null,
      selectedElementKeys: new Set(),
      axElementCache: new Map(),
      axCache: new Map(),
      sourceRoot: localStorage.getItem('agentsim.review.sourceRoot')
        || localStorage.getItem('baguette.review.sourceRoot') || '',
      tasks: [],
      lastTask: null,
      taskStream: null,
      taskStreamSessionId: null,
      taskStreamStatus: 'offline',
      taskStreamReconnectTimer: null,
      taskStreamReconnectAttempt: 0,
      axText: ''
    };
  }

  FarmApp.prototype.boot = async function () {
    this.applyViewportMode();
    window.addEventListener('resize', () => this.applyViewportMode());
    await this.refreshDevices();
    await this.refreshReviews();
    // Bezels are on by default — pre-fetch chrome layouts before the
    // first paint so tiles mount with their bezel chrome on the
    // initial render rather than flashing raw → bezel as layouts
    // arrive. Fetches run in parallel; failures are tolerated (Apple
    // TV / watchOS have no chrome bundle and DeviceFrame falls back
    // to a flat fill).
    if (this.showBezels) await this.loadChromeLayouts();
    this.renderAll();
    this.startVisibleTiles();
    this.bindGlobalKeys();
    this.startClock();
  };

  FarmApp.prototype.applyViewportMode = function () {
    const narrow = window.matchMedia('(max-width: 820px)').matches;
    document.documentElement.classList.toggle('farm-mobile-boot', this.mobileMode);
    document.body.classList.toggle('farm-mobile', this.mobileMode);
    document.body.classList.toggle('farm-narrow', narrow);
  };

  // ---- device discovery ---------------------------------------------
  FarmApp.prototype.refreshDevices = async function () {
    try {
      const res = await fetch('/simulators.json');
      const json = await res.json();
      const all = [...(json.running || []), ...(json.available || [])];
      this.devices = all.map(d => normalizeDevice(d));
      this.filter.seedRuntimes(uniq(this.devices.map(d => d.runtime)));
    } catch (e) {
      this.devices = [];
      console.error('[FarmApp] device fetch failed', e);
    }
  };

  // ---- render --------------------------------------------------------
  FarmApp.prototype.renderAll = function () {
    const visible = this.filter.apply(this.devices);
    const sorted = this.sortFor(this.view, visible);
    const ctx = this.renderCtx(sorted);

    window.FarmViews.renderHeader(byId('farm-header'), ctx);
    window.FarmViews.renderRail(byId('farm-rail'), ctx);
    window.FarmViews.renderGridHead(byId('farm-grid-head'), ctx);
    window.FarmViews.renderCli(byId('farm-cli'), ctx);

    const host = byId(VIEW_HOST_ID);
    if (this.view === 'grid') window.FarmViews.renderGrid(host, sorted, ctx);
    if (this.view === 'wall') window.FarmViews.renderWall(host, sorted, ctx);
    if (this.view === 'list') window.FarmViews.renderList(host, sorted, ctx);
    if (this.view === 'review') window.FarmViews.renderReview(host, this.review, ctx);

    // Empty state for the focus pane on first render.
    if (this.view === 'review') {
      this.renderReviewFocus();
    } else if (!this.selectedUdid && !this.focus) {
      window.FarmViews.renderFocusEmpty(byId('farm-focus'));
    }

    this.bindAfterRender();
    this.attachTilesToScreens();
  };

  FarmApp.prototype.renderCtx = function (visible) {
    const counts = this.filter.counts(this.devices);
    const fleet = {
      live:  this.devices.filter(d => d.uiState === 'live').length,
      total: this.devices.length,
      fps:   this.fleetTelemetry.fps,
      bw:    this.fleetTelemetry.bw,
      lat:   this.fleetTelemetry.lat
    };
    return {
      filter: this.filter,
      view: this.view,
      sort: this.sort,
      visible: visible.length,
      total: this.devices.length,
      search: this.filter.search,
      runtimes: [...this.filter.runtimes].sort(),
      counts, fleet,
      display: { bezel: this.showBezels },
      mobile: this.mobileMode,
      selectedUdid: this.selectedUdid,
      review: {
        sessions: this.review.sessions,
        session: this.review.session,
        selectedCount: this.review.selectedSnapshotIds.size
      },
      devicesByUdid: Object.fromEntries(this.devices.map(d => [d.udid, d]))
    };
  };

  // ---- review state -------------------------------------------------
  FarmApp.prototype.refreshReviews = async function () {
    try {
      const res = await fetch('/reviews.json');
      this.review.sessions = await res.json();
      const current = this.review.session;
      if (current) {
        const fresh = this.review.sessions.find(s => s.id === current.id);
        if (fresh) this.review.session = fresh;
      } else if (this.review.sessions.length) {
        this.review.session = this.review.sessions[0];
      }
      this.connectReviewTaskStream(this.review.session?.id || null);
    } catch (e) {
      console.error('[FarmApp] review fetch failed', e);
      this.review.sessions = [];
      this.connectReviewTaskStream(null);
    }
  };

  FarmApp.prototype.createReview = async function () {
    const name = prompt('Review name', 'Farm review');
    if (name == null) return;
    const res = await fetch('/reviews', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ name: name || 'Farm review' })
    });
    this.review.session = await res.json();
    this.review.selectedSnapshotId = null;
    this.review.selectedSnapshotIds.clear();
    this.review.selectedElementPath = '';
    this.review.selectedElementFrame = null;
    this.review.selectedElementKeys.clear();
    this.review.tasks = [];
    this.review.lastTask = null;
    this.connectReviewTaskStream(this.review.session.id);
    await this.refreshReviews();
    this.view = 'review';
    this.renderAll();
  };

  FarmApp.prototype.loadReviewSession = async function (id) {
    if (!id) {
      this.review.session = null;
      this.review.selectedSnapshotId = null;
      this.review.selectedSnapshotIds.clear();
      this.review.selectedElementPath = '';
      this.review.selectedElementFrame = null;
      this.review.selectedElementKeys.clear();
      this.review.tasks = [];
      this.review.lastTask = null;
      this.connectReviewTaskStream(null);
      this.renderAll();
      return;
    }
    const res = await fetch(`/reviews/${encodeURIComponent(id)}/manifest.json`);
    this.review.session = await res.json();
    this.review.selectedSnapshotId = null;
    this.review.selectedSnapshotIds.clear();
    this.review.selectedElementPath = '';
    this.review.selectedElementFrame = null;
    this.review.selectedElementKeys.clear();
    this.review.axText = '';
    this.review.lastTask = null;
    await this.refreshReviewTasks();
    this.connectReviewTaskStream(id);
    this.renderAll();
  };

  FarmApp.prototype.captureReview = async function (udid, actionType) {
    if (!udid) return;
    if (!this.review.session) await this.createReview();
    if (!this.review.session) return;
    const fromSnapshotId = this.review.selectedSnapshotId || null;
    const res = await fetch(`/reviews/${encodeURIComponent(this.review.session.id)}/capture`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ udid, fromSnapshotId, actionType: actionType || 'manual' })
    });
    if (!res.ok) {
      console.warn('[FarmApp] review capture failed', await res.text());
      return;
    }
    const result = await res.json();
    this.review.session = result.session;
    this.review.sessions = [result.session, ...this.review.sessions.filter(s => s.id !== result.session.id)];
    this.review.selectedSnapshotId = result.snapshot.id;
    this.review.selectedSnapshotIds = new Set([result.snapshot.id]);
    this.review.selectedElementPath = '';
    this.review.selectedElementFrame = null;
    this.view = 'review';
    await this.loadReviewAX(result.snapshot);
    this.renderAll();
  };

  FarmApp.prototype.selectReviewSnapshot = async function (snapshot, additive) {
    if (!snapshot) return;
    this.review.selectedSnapshotId = snapshot.id;
    if (additive) {
      if (this.review.selectedSnapshotIds.has(snapshot.id)) this.review.selectedSnapshotIds.delete(snapshot.id);
      else this.review.selectedSnapshotIds.add(snapshot.id);
    } else {
      this.review.selectedSnapshotIds = new Set([snapshot.id]);
    }
    this.review.selectedElementPath = '';
    this.review.selectedElementFrame = null;
    await this.loadReviewAX(snapshot);
    this.renderAll();
  };

  FarmApp.prototype.loadReviewAXData = async function (snapshot) {
    if (!this.review.session || !snapshot) return { text: '', elements: [], rootFrame: null };
    if (this.review.axCache.has(snapshot.id)) {
      return {
        text: this.review.axCache.get(snapshot.id),
        elements: this.review.axElementCache.get(snapshot.id) || [],
        rootFrame: this.review.axRootFrameCache?.get(snapshot.id) || null
      };
    }
    const stored = normalizeStoredReviewElements(snapshot);
    if (stored.elements.length) {
      this.review.axElementCache.set(snapshot.id, stored.elements);
      if (!this.review.axRootFrameCache) this.review.axRootFrameCache = new Map();
      this.review.axRootFrameCache.set(snapshot.id, stored.rootFrame);
    }
    const url = `/reviews/${encodeURIComponent(this.review.session.id)}/artifact?path=${encodeURIComponent(snapshot.axPath)}`;
    const text = await fetch(url).then(r => r.text()).catch(() => '');
    const parsed = stored.elements.length ? stored : parseAXTree(text);
    this.review.axCache.set(snapshot.id, text);
    this.review.axElementCache.set(snapshot.id, parsed.elements);
    if (!this.review.axRootFrameCache) this.review.axRootFrameCache = new Map();
    this.review.axRootFrameCache.set(snapshot.id, parsed.rootFrame);
    return { text, elements: parsed.elements, rootFrame: parsed.rootFrame };
  };

  FarmApp.prototype.loadReviewAX = async function (snapshot) {
    if (!this.review.session || !snapshot) { this.review.axText = ''; return; }
    const data = await this.loadReviewAXData(snapshot);
    const selected = data.elements.find(e => e.path === this.review.selectedElementPath);
    if (selected) this.review.selectedElementFrame = selected.frame;
    this.review.axText = data.text;
  };

  FarmApp.prototype.saveReviewComment = async function () {
    return this.saveReviewComments(false);
  };

  FarmApp.prototype.saveReviewComments = async function (allSelected) {
    const session = this.review.session;
    const snap = this.review.selectedSnapshot;
    if (!session || !snap) return;
    const path = document.querySelector('#farm-focus [data-review-path]')?.value.trim() || '/';
    const text = document.querySelector('#farm-focus [data-review-comment]')?.value.trim();
    if (!text) return;
    const targets = allSelected && this.review.selectedElementKeys.size
      ? [...this.review.selectedElementKeys].map(splitElementKey).filter(Boolean)
      : [{ snapshotId: snap.id, path, frame: this.review.selectedElementFrame }];

    for (const target of targets) {
      let frame = target.frame || null;
      if (!frame) {
        const targetSnap = session.snapshots.find(s => s.id === target.snapshotId);
        if (targetSnap) {
          const data = await this.loadReviewAXData(targetSnap);
          frame = data.elements.find(e => e.path === target.path)?.frame || null;
        }
      }
      const res = await fetch(`/reviews/${encodeURIComponent(session.id)}/comments`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          snapshotId: target.snapshotId,
          axNodePath: target.path || path,
          frame: reviewFramePayload(frame),
          text,
          status: 'open'
        })
      });
      if (!res.ok) return;
    }
    const restoredKeys = new Set(targets.map(t => elementKey(t.snapshotId, t.path || path)));
    await this.loadReviewSession(session.id);
    this.review.selectedSnapshotId = snap.id;
    this.review.selectedSnapshotIds.add(snap.id);
    this.review.selectedElementKeys = restoredKeys;
    this.review.selectedElementPath = path;
    await this.loadReviewAX(snap);
    this.renderAll();
  };

  FarmApp.prototype.bundleReviewSelection = async function () {
    const session = this.review.session;
    const ids = [...this.review.selectedSnapshotIds];
    if (!session || !ids.length) return;
    const preservedElementKeys = new Set(this.review.selectedElementKeys);
    const preservedSnapshotId = this.review.selectedSnapshotId;
    const preservedElementPath = this.review.selectedElementPath;
    const res = await fetch(`/reviews/${encodeURIComponent(session.id)}/bundles`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ snapshotIds: ids })
    });
    if (!res.ok) return;
    const bundle = await res.json();
    await this.loadReviewSession(session.id);
    this.review.selectedSnapshotId = preservedSnapshotId;
    this.review.selectedElementPath = preservedElementPath;
    this.review.selectedElementKeys = preservedElementKeys;
    this.review.selectedSnapshotIds = new Set(ids);
    await this.copyReviewSelectionContext(bundle);
    if (this.review.selectedSnapshotId) {
      const snap = this.review.session.snapshots.find(s => s.id === this.review.selectedSnapshotId);
      if (snap) await this.loadReviewAX(snap);
    }
    this.renderAll();
  };

  FarmApp.prototype.queueReviewTask = async function () {
    const session = this.review.session;
    const ids = [...this.review.selectedSnapshotIds];
    if (!session || !ids.length) return;
    const comment = document.querySelector('#farm-focus [data-review-comment]')?.value.trim() || '';
    const selection = await this.reviewSelectionContext();
    const contextMarkdown = formatReviewSelectionContext(session, selection, null);
    const title = comment
      ? comment.split(/\n/)[0].slice(0, 90)
      : `Review ${selection.filter(x => x.element).length || ids.length} selected item(s)`;
    const elements = [...this.review.selectedElementKeys]
      .map(splitElementKey)
      .filter(Boolean)
      .map(target => ({
        snapshotId: target.snapshotId,
        axNodePath: target.path,
        commentText: comment || undefined
      }));
    const res = await fetch(`/reviews/${encodeURIComponent(session.id)}/tasks`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        title,
        instructions: comment || undefined,
        priority: 'normal',
        snapshotIds: ids,
        elements,
        contextMarkdown
      })
    });
    if (!res.ok) {
      console.warn('[FarmApp] review task queue failed', await res.text());
      return;
    }
    this.review.lastTask = await res.json();
    await this.refreshReviewTasks();
    try {
      const text = `${contextMarkdown}\n\nQueued task: ${this.review.lastTask.id}`;
      this.review.lastCopiedContext = text;
      await navigator.clipboard?.writeText(text);
    } catch (error) {
      console.warn('[FarmApp] clipboard write failed after queue; context retained in review.lastCopiedContext', error);
    }
    this.renderAll();
  };

  FarmApp.prototype.refreshReviewTasks = async function () {
    const session = this.review.session;
    if (!session) { this.review.tasks = []; return; }
    try {
      const res = await fetch(`/review-tasks.json?sessionId=${encodeURIComponent(session.id)}`);
      this.review.tasks = res.ok ? await res.json() : [];
    } catch (error) {
      console.warn('[FarmApp] task refresh failed', error);
      this.review.tasks = [];
    }
  };

  FarmApp.prototype.connectReviewTaskStream = function (sessionId, options = {}) {
    const force = Boolean(options.force);
    if (!force && this.review.taskStreamSessionId === sessionId && this.review.taskStream) return;
    if (this.review.taskStreamReconnectTimer) {
      clearTimeout(this.review.taskStreamReconnectTimer);
      this.review.taskStreamReconnectTimer = null;
    }
    if (this.review.taskStream) {
      try { this.review.taskStream.close(); } catch {}
      this.review.taskStream = null;
    }
    this.review.taskStreamSessionId = sessionId || null;
    if (!sessionId) {
      this.review.taskStreamStatus = 'offline';
      this.review.taskStreamReconnectAttempt = 0;
      this.renderAll();
      return;
    }
    this.review.taskStreamStatus = force && this.review.taskStreamReconnectAttempt ? 'reconnecting' : 'connecting';
    this.renderAll();
    const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const ws = new WebSocket(`${protocol}//${location.host}/review-tasks/stream?sessionId=${encodeURIComponent(sessionId)}`);
    this.review.taskStream = ws;
    this.review.taskStreamSessionId = sessionId;
    ws.onopen = () => {
      if (this.review.taskStream !== ws) return;
      this.review.taskStreamStatus = 'live';
      this.review.taskStreamReconnectAttempt = 0;
      this.renderAll();
    };
    ws.onmessage = (event) => {
      let payload = null;
      try { payload = JSON.parse(event.data); } catch { return; }
      if (payload.type === 'task_snapshot' && Array.isArray(payload.tasks)) {
        this.review.tasks = payload.tasks;
        this.renderAll();
      } else if (payload.type === 'task_update' && payload.task) {
        this.review.tasks = [payload.task, ...this.review.tasks.filter(t => t.id !== payload.task.id)];
        this.review.lastTask = payload.task;
        this.renderAll();
      } else if (payload.type === 'task_stream_error') {
        this.review.taskStreamStatus = 'error';
        console.warn('[FarmApp] task stream error', payload.error);
        this.renderAll();
      }
    };
    ws.onclose = () => {
      if (this.review.taskStream !== ws) return;
      this.review.taskStream = null;
      const stillCurrent = this.review.taskStreamSessionId === sessionId && this.review.session?.id === sessionId;
      if (!stillCurrent) {
        this.review.taskStreamStatus = 'offline';
        this.renderAll();
        return;
      }
      this.review.taskStreamStatus = 'reconnecting';
      const attempt = Math.min(this.review.taskStreamReconnectAttempt + 1, 6);
      this.review.taskStreamReconnectAttempt = attempt;
      const delay = Math.min(10000, 750 * Math.pow(2, attempt - 1));
      this.review.taskStreamReconnectTimer = setTimeout(() => {
        this.review.taskStreamReconnectTimer = null;
        if (this.review.session?.id === sessionId) {
          this.connectReviewTaskStream(sessionId, { force: true });
        }
      }, delay);
      this.renderAll();
    };
    ws.onerror = () => {
      if (this.review.taskStream !== ws) return;
      this.review.taskStreamStatus = 'error';
      this.renderAll();
    };
  };

  FarmApp.prototype.copyReviewSelectionContext = async function (bundle) {
    const session = this.review.session;
    if (!session) return;
    const selection = await this.reviewSelectionContext();
    const text = formatReviewSelectionContext(session, selection, bundle);
    this.review.lastCopiedContext = text;
    try {
      await navigator.clipboard?.writeText(text);
    } catch (error) {
      console.warn('[FarmApp] clipboard write failed; context retained in review.lastCopiedContext', error);
    }
    this.renderAll();
  };

  FarmApp.prototype.reviewSelectionContext = async function () {
    const session = this.review.session;
    if (!session) return [];
    const keys = [...this.review.selectedElementKeys];
    const targets = keys.length
      ? keys.map(splitElementKey).filter(Boolean)
      : [...this.review.selectedSnapshotIds].map(snapshotId => ({ snapshotId, path: null }));
    const contexts = [];
    for (const target of targets) {
      const snapshot = session.snapshots.find(s => s.id === target.snapshotId);
      if (!snapshot) continue;
      const data = await this.loadReviewAXData(snapshot);
      if (target.path) {
        const element = data.elements.find(e => e.path === target.path);
        if (!element) continue;
        contexts.push(await buildElementContext(this.review, session, snapshot, element, data.elements));
      } else {
        contexts.push({ snapshot, element: null, ancestors: [], comments: commentsFor(session, snapshot.id, null) });
      }
    }
    return contexts;
  };

  // ---- event wiring (post-render) -----------------------------------
  FarmApp.prototype.bindAfterRender = function () {
    // Filter checkboxes
    document.querySelectorAll('#farm-rail input[data-platform]').forEach(el =>
      el.onchange = () => { this.filter.toggle('platforms', el.dataset.platform); this.renderAll(); });
    document.querySelectorAll('#farm-rail input[data-state]').forEach(el =>
      el.onchange = () => { this.filter.toggle('states', el.dataset.state); this.renderAll(); });
    document.querySelectorAll('#farm-rail .runtime-pill').forEach(p =>
      p.onclick = () => { this.filter.toggle('runtimes', p.dataset.runtime); this.renderAll(); });

    // Display toggles (bezel, future: scanlines / crosshairs / grid pitch).
    document.querySelectorAll('#farm-rail input[data-display]').forEach(el =>
      el.onchange = () => this.toggleDisplay(el.dataset.display, el.checked));

    const reviewSession = document.querySelector('#farm-grid-head [data-review-session]');
    if (reviewSession) {
      reviewSession.onchange = () => this.loadReviewSession(reviewSession.value);
    }
    document.querySelectorAll('#farm-grid-head [data-review]').forEach(btn =>
      btn.onclick = () => this.runReviewAction(btn.dataset.review));

    // Bulk actions
    document.querySelectorAll('#farm-rail [data-bulk]').forEach(b =>
      b.onclick = () => this.runBulk(b.dataset.bulk));

    // Search + view toggle
    const search = document.querySelector('#farm-grid-head [data-role="search"]');
    if (search) {
      search.oninput = () => { this.filter.search = search.value; this.renderAll(); search.focus(); };
    }
    document.querySelectorAll('#farm-grid-head [data-view]').forEach(b =>
      b.onclick = () => {
        const wasReview = this.view === 'review';
        this.view = b.dataset.view;
        if (wasReview && this.view !== 'review' && this.selectedUdid) {
          const udid = this.selectedUdid;
          this.selectedUdid = null;
          this.select(udid);
        }
        this.renderAll();
      });

    // List sort
    document.querySelectorAll('#farm-view-host .sortable').forEach(el =>
      el.onclick = () => {
        const key = el.dataset.key;
        if (this.sort.key === key) this.sort.dir = this.sort.dir === 'asc' ? 'desc' : 'asc';
        else { this.sort.key = key; this.sort.dir = 'asc'; }
        this.renderAll();
      });

    // Tile / row / panel click → select. Quick-action buttons inside
    // stop propagation so the tile click doesn't fight the action.
    document.querySelectorAll('#farm-view-host [data-udid]').forEach(node =>
      node.onclick = (e) => {
        if (e.target.closest('[data-action]')) return;
        this.select(node.dataset.udid);
      });
    document.querySelectorAll('#farm-view-host [data-action]').forEach(btn =>
      btn.onclick = (e) => {
        e.stopPropagation();
        const node = btn.closest('[data-udid]');
        if (node) this.runAction(node.dataset.udid, btn.dataset.action);
      });

    document.querySelectorAll('#farm-view-host [data-review-snapshot]').forEach(node =>
      node.onclick = (e) => {
        const snap = this.review.session?.snapshots.find(s => s.id === node.dataset.reviewSnapshot);
        this.selectReviewSnapshot(snap, e.metaKey || e.ctrlKey);
      });

    document.querySelectorAll('#farm-focus [data-review-action]').forEach(btn =>
      btn.onclick = () => this.runReviewAction(btn.dataset.reviewAction));

    document.querySelectorAll('#farm-focus [data-review-element]').forEach(btn =>
      btn.onclick = (e) => this.selectReviewElement(btn.dataset.reviewElement, e.metaKey || e.ctrlKey));

    const pathInput = document.querySelector('#farm-focus [data-review-path]');
    if (pathInput) {
      pathInput.onchange = () => this.selectReviewElement(pathInput.value.trim(), false, false);
    }

    // CLI copy
    const copy = document.querySelector('#farm-cli .copy');
    if (copy) {
      copy.onclick = () => {
        const cmd = document.querySelector('#farm-cli .cmd')?.innerText || '';
        navigator.clipboard?.writeText(cmd.replace(/^\$\s*/, '').trim());
      };
    }
  };

  FarmApp.prototype.runReviewAction = function (action) {
    if (action === 'new') return this.createReview();
    if (action === 'capture') return this.captureReview(this.selectedUdid, 'manual');
    if (action === 'save-comment') return this.saveReviewComment();
    if (action === 'save-comment-all') return this.saveReviewComments(true);
    if (action === 'bundle') return this.bundleReviewSelection();
    if (action === 'queue-task') return this.queueReviewTask();
    if (action === 'copy-context') return this.copyReviewSelectionContext();
    if (action === 'clear-elements') {
      this.review.selectedElementKeys.clear();
      this.review.selectedElementPath = '';
      this.review.selectedElementFrame = null;
      return this.renderAll();
    }
    if (action === 'toggle-pick') {
      const snap = this.review.selectedSnapshot;
      if (!snap) return;
      if (this.review.selectedSnapshotIds.has(snap.id)) this.review.selectedSnapshotIds.delete(snap.id);
      else this.review.selectedSnapshotIds.add(snap.id);
      return this.renderAll();
    }
    if (action === 'clear') {
      this.review.selectedSnapshotId = null;
      this.review.axText = '';
      return this.renderAll();
    }
  };

  FarmApp.prototype.selectReviewElement = function (path, additive, rerender = true) {
    const snap = this.review.selectedSnapshot;
    if (!snap || !path) return;
    const elements = this.review.axElementCache.get(snap.id) || [];
    const element = elements.find(e => e.path === path);
    this.review.selectedElementPath = path;
    this.review.selectedElementFrame = element?.frame || null;
    const key = elementKey(snap.id, path);
    if (additive) {
      if (this.review.selectedElementKeys.has(key)) this.review.selectedElementKeys.delete(key);
      else this.review.selectedElementKeys.add(key);
    } else {
      this.review.selectedElementKeys = new Set([key]);
    }
    this.review.selectedSnapshotIds.add(snap.id);
    if (rerender) this.renderAll();
  };

  FarmApp.prototype.renderReviewFocus = function () {
    const session = this.review.session;
    this.review.selectedSnapshot = session && this.review.selectedSnapshotId
      ? session.snapshots.find(s => s.id === this.review.selectedSnapshotId)
      : null;
    if (this.review.selectedSnapshot) {
      this.review.currentAxElements = this.review.axElementCache.get(this.review.selectedSnapshot.id) || [];
      this.review.currentAxRootFrame = this.review.axRootFrameCache?.get(this.review.selectedSnapshot.id) || null;
    } else {
      this.review.currentAxElements = [];
      this.review.currentAxRootFrame = null;
    }
    this.review.selectedElementContexts = this.buildCachedSelectedElementContexts();
    window.FarmViews.renderReviewFocus(
      byId('farm-focus'),
      this.review,
      this.review.axText
    );
  };

  FarmApp.prototype.buildCachedSelectedElementContexts = function () {
    const session = this.review.session;
    if (!session) return [];
    return [...this.review.selectedElementKeys].map(splitElementKey).filter(Boolean).map(target => {
      const snapshot = session.snapshots.find(s => s.id === target.snapshotId);
      const elements = snapshot ? (this.review.axElementCache.get(snapshot.id) || []) : [];
      const element = elements.find(e => e.path === target.path);
      if (!snapshot || !element) return null;
      const ancestors = elementAncestors(element, elements);
      return {
        snapshot,
        element,
        ancestors,
        comments: commentsFor(session, snapshot.id, element.path),
        componentHints: componentHints(element, ancestors),
        sourceReferences: null
      };
    }).filter(Boolean);
  };

  // ---- tiles ---------------------------------------------------------
  FarmApp.prototype.startVisibleTiles = function () {
    this.devices.forEach(d => {
      if (d.uiState === 'live' && !this.tiles.has(d.udid)) {
        const tile = new window.FarmTile({
          device: d,
          onTelemetry: (udid, t) => this.onTileTelemetry(udid, t)
        });
        this.tiles.set(d.udid, tile);
        tile.start();
      }
    });
    // Drop tiles whose device disappeared.
    for (const udid of [...this.tiles.keys()]) {
      if (!this.devices.find(d => d.udid === udid && d.uiState === 'live')) {
        this.tiles.get(udid).stop();
        this.tiles.delete(udid);
      }
    }
    this.attachTilesToScreens();
  };

  // After every render, walk the produced screen-host nodes and ask
  // each tile to install its canvas. All views honor the global
  // bezel toggle uniformly so the device-farm aesthetic carries
  // across grid / wall / list.
  FarmApp.prototype.attachTilesToScreens = function () {
    document.querySelectorAll('#farm-view-host [data-screen-host]').forEach(host => {
      const udid = host.dataset.screenHost;
      const tile = this.tiles.get(udid);
      if (!tile) return;
      tile.attach(host, {
        useBezel: this.showBezels,
        layout:   this.chromeLayouts.get(udid) || null
      });
    });
  };

  // ---- bezel toggle --------------------------------------------------
  FarmApp.prototype.toggleDisplay = async function (kind, enabled) {
    if (kind !== 'bezel') return;
    this.showBezels = enabled;
    if (enabled) {
      await this.loadChromeLayouts();
    }
    this.renderAll();
  };

  // Lazy chrome-layout fetch — only paid for once the user actually
  // wants bezels. Hits `/simulators/<udid>/chrome.json` per device;
  // a 404 means DeviceKit has no chrome bundle (Apple TV, watchOS),
  // and DeviceFrame falls back to a flat fill in that case.
  FarmApp.prototype.loadChromeLayouts = async function () {
    const need = this.devices.filter(d =>
      d.uiState !== 'off' && !this.chromeLayouts.has(d.udid));
    await Promise.allSettled(need.map(async d => {
      try {
        const res = await fetch(`/simulators/${encodeURIComponent(d.udid)}/chrome.json`);
        if (!res.ok) { this.chromeLayouts.set(d.udid, null); return; }
        const layout = await res.json();
        this.chromeLayouts.set(d.udid, layout);
      } catch {
        this.chromeLayouts.set(d.udid, null);
      }
    }));
  };

  // ---- selection / focus --------------------------------------------
  FarmApp.prototype.select = function (udid) {
    if (this.selectedUdid === udid) return;
    if (this.selectedUdid) {
      const prev = this.tiles.get(this.selectedUdid);
      if (prev) prev.demote();
    }
    this.selectedUdid = udid;
    const device = this.devices.find(d => d.udid === udid);
    const tile = this.tiles.get(udid);
    if (!device) return;

    this.focus = this.focus || new window.FarmFocus(byId('farm-focus'));
    this.focus.show(device, tile, {
      onClose: () => this.clearFocus(),
      onOpenTab: (d) => window.open(`/simulators/${encodeURIComponent(d.udid)}`, '_blank'),
      onLifecycle: (d, action) => this.runAction(d.udid, action),
      onButton: (name) => tile?.button(name),
      onReviewNew: () => this.createReview(),
      onReviewCapture: (d, kind) => this.captureReview(d.udid, kind === 'accessibility' ? 'accessibility-screen' : (kind || 'manual-focus')),
      onReviewOpen: () => { this.view = 'review'; this.renderAll(); },
      onReviewBundle: () => this.bundleReviewSelection(),
      // Hand the recorder a snapshot of the focused tile's existing
      // page elements at click time — re-evaluated on each Record
      // press so a re-focus mid-session can't strand the recorder on
      // a stale tile. The recorder doesn't fetch anything new; the
      // bezel <img> already lives inside the focus preview, the layout
      // was cached when bezels were enabled, and PinchOverlay's DOM
      // container is whatever the tile's current input wiring built.
      getRecorderContext: () => {
        const focusScreen = this.focus && this.focus.previewScreen;
        return {
          canvas: tile?.canvas || null,
          frameImg: focusScreen ? focusScreen.querySelector('img') : null,
          layout: this.chromeLayouts.get(udid) || null,
          overlayHost: tile?.pinchOverlay ? tile.pinchOverlay.container : null,
        };
      },
    });
    // Selection only affects two things — the highlight class on the
    // grid tile, and the focus pane content. The grid canvas keeps
    // painting in place; we install a mirror <video> in the focus
    // preview so the user sees the same frames at full size.
    this.applySelectionHighlight();
    const layout = this.chromeLayouts.get(udid) || null;
    if (tile && this.focus.previewScreen) {
      tile.attachMirror(this.focus.previewScreen, { useBezel: this.showBezels, layout });
    }
    // Bump stream quality + wire input on the mirror.
    if (tile) tile.promote({ layout });

    // AX overlay + activity dock + selection dock for the focused tile.
    // The inspector shares the tile's WS for describe_ui round-trips;
    // we route the tile's onText through it so describe_ui_result
    // envelopes land on the right consumer.
    if (tile && this.focus.previewScreen && window.AXInspector) {
      const inspector = new window.AXInspector({
        screenArea:    this.focus.previewScreen,
        send:          (payload) => tile.send(payload),
        getDeviceSize: () => {
          const sz = tile.computeScreenSize();
          return { w: sz[0], h: sz[1] };
        },
      });
      tile.onText = (env) => inspector.handleEnvelope(env);
      this._focusInspector = inspector;
      if (window.AgentSimReviewClient && window.AgentSimReviewClient.attachToFocus) {
        this._focusDocks = window.AgentSimReviewClient.attachToFocus({
          host: this.focus.host,
          getUdid: () => udid,
          getInspector: () => inspector,
        });
      }
    }
  };

  // Flip the .selected class on grid tiles + refresh the CLI footer
  // (which carries the `--focus` arg). Header / rail / grid-head /
  // tile contents are untouched — no flicker.
  FarmApp.prototype.applySelectionHighlight = function () {
    document.querySelectorAll('#farm-view-host [data-udid]').forEach(node =>
      node.classList.toggle('selected', node.dataset.udid === this.selectedUdid));
    const reviewCapture = document.querySelector('#farm-grid-head [data-review="capture"]');
    if (reviewCapture) reviewCapture.disabled = !this.selectedUdid;
    const reviewBundle = document.querySelector('#farm-grid-head [data-review="bundle"]');
    if (reviewBundle) reviewBundle.disabled = this.review.selectedSnapshotIds.size === 0;
    const reviewQueue = document.querySelector('#farm-grid-head [data-review="queue-task"]');
    if (reviewQueue) reviewQueue.disabled = this.review.selectedSnapshotIds.size === 0;
    const ctx = this.renderCtx(this.filter.apply(this.devices));
    window.FarmViews.renderCli(byId('farm-cli'), ctx);
    const copy = document.querySelector('#farm-cli .copy');
    if (copy) {
      copy.onclick = () => {
        const cmd = document.querySelector('#farm-cli .cmd')?.innerText || '';
        navigator.clipboard?.writeText(cmd.replace(/^\$\s*/, '').trim());
      };
    }
  };

  FarmApp.prototype.clearFocus = function () {
    if (this._focusDocks) { this._focusDocks.unmount(); this._focusDocks = null; }
    if (this._focusInspector) {
      try { this._focusInspector.detach(); } catch { /* ignore */ }
      this._focusInspector = null;
    }
    if (this.selectedUdid) {
      const tile = this.tiles.get(this.selectedUdid);
      if (tile) {
        tile.onText = null;
        tile.demote();
      }
    }
    this.selectedUdid = null;
    if (this.focus) { this.focus.dispose(); }
    this.applySelectionHighlight();
  };

  // ---- per-tile telemetry → fleet aggregate -------------------------
  FarmApp.prototype.onTileTelemetry = function (udid, t) {
    // Update the per-tile readouts in the live DOM without re-rendering.
    document.querySelectorAll(`#farm-view-host [data-udid="${cssEscape(udid)}"] [data-readout="fps"]`)
      .forEach(el => el.textContent = t.fps + ' fps');
    if (this.selectedUdid === udid && this.focus) {
      this.focus.updateTelemetry(t);
    }
    // Crude fleet roll-up: sum per-tile fps every second.
    let total = 0;
    this.tiles.forEach(tile => total += (tile.lastFps || 0));
    this.fleetTelemetry.fps = total;
    document.querySelectorAll('#farm-header [data-stat="fps"]').forEach(el => el.textContent = total);
  };

  // ---- actions -------------------------------------------------------
  FarmApp.prototype.runAction = async function (udid, action) {
    if (action === 'snapshot')  { this.tiles.get(udid)?.snapshot(); return; }
    if (action === 'reset')     { this.tiles.get(udid)?.forceIdr(); return; }
    if (action === 'open')      { window.open(`/simulators/${encodeURIComponent(udid)}`, '_blank'); return; }
    if (action === 'force-idr') { this.tiles.get(udid)?.forceIdr(); return; }
    if (action === 'boot')      { await this.lifecycle(udid, 'boot');     return; }
    if (action === 'shutdown')  { await this.lifecycle(udid, 'shutdown'); return; }
    if (action === 'restart')   {
      await this.lifecycle(udid, 'shutdown');
      await this.lifecycle(udid, 'boot');
      return;
    }
  };

  FarmApp.prototype.lifecycle = async function (udid, verb) {
    try {
      await fetch(`/simulators/${encodeURIComponent(udid)}/${verb}`, { method: 'POST' });
      await this.refreshDevices();
      this.startVisibleTiles();
      this.renderAll();
    } catch (e) {
      console.error(`[FarmApp] ${verb} failed`, e);
    }
  };

  FarmApp.prototype.runBulk = async function (kind) {
    const visible = this.filter.apply(this.devices);
    if (kind === 'snapshot') { visible.forEach(d => this.tiles.get(d.udid)?.snapshot()); return; }
    if (kind === 'reset')    { visible.forEach(d => this.tiles.get(d.udid)?.forceIdr()); return; }
    if (kind === 'boot' || kind === 'shutdown') {
      await Promise.allSettled(visible.map(d =>
        fetch(`/simulators/${encodeURIComponent(d.udid)}/${kind}`, { method: 'POST' })));
      await this.refreshDevices();
      this.startVisibleTiles();
      this.renderAll();
    }
  };

  // ---- sort (only meaningful for List view) -------------------------
  FarmApp.prototype.sortFor = function (mode, devices) {
    if (mode !== 'list') return devices;
    const { key, dir } = this.sort;
    const mul = dir === 'asc' ? 1 : -1;
    const get = d => ({
      name:    d.name.toLowerCase(),
      runtime: d.runtime,
      state:   d.uiState,
      fps:     this.tiles.get(d.udid)?.lastFps || 0,
      lat:     0,
      scale:   0
    }[key]);
    return [...devices].sort((a, b) => {
      const A = get(a), B = get(b);
      return A < B ? -mul : A > B ? mul : 0;
    });
  };

  // ---- misc ----------------------------------------------------------
  FarmApp.prototype.bindGlobalKeys = function () {
    document.addEventListener('keydown', e => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
        e.preventDefault();
        document.querySelector('#farm-grid-head [data-role="search"]')?.focus();
      }
    });
  };

  FarmApp.prototype.startClock = function () {
    setInterval(() => {
      const t = new Date();
      const pad = n => String(n).padStart(2, '0');
      document.querySelectorAll('[data-stat="clock"]').forEach(el =>
        el.textContent = `${pad(t.getHours())}:${pad(t.getMinutes())}:${pad(t.getSeconds())}`);
    }, 1000);
  };

  // ---- helpers -------------------------------------------------------
  // CoreSimulator state strings → UI states. Booted defaults to "live"
  // because we open a thumbnail stream against every booted device.
  function normalizeDevice(d) {
    const platform = inferPlatform(d.name);
    let uiState = 'off';
    if (d.state === 'Booted')          uiState = 'live';
    else if (d.state === 'Booting')    uiState = 'boot';
    else if (d.state === 'Shutting Down') uiState = 'boot';
    else if (d.state === 'Shutdown')   uiState = 'off';
    return {
      udid: d.udid,
      name: d.name,
      runtime: d.runtime,
      state: d.state,
      platform,
      uiState
    };
  }

  function inferPlatform(name) {
    const n = name.toLowerCase();
    if (n.includes('ipad'))         return 'ipad';
    if (n.includes('apple tv'))     return 'tv';
    if (n.includes('apple watch'))  return 'watch';
    return 'iphone';
  }

  function parseAXTree(text) {
    try {
      const root = JSON.parse(text);
      if (!root || typeof root !== 'object') return { elements: [], rootFrame: null };
      const rootFrame = normalizeFrame(root.frame);
      const elements = [];
      const walk = (node, path, depth) => {
        if (!node || typeof node !== 'object') return;
        const frame = normalizeFrame(node.frame);
        const label = node.label || node.title || node.value || node.identifier || node.role || path;
        if (frame && frame.width > 0 && frame.height > 0 && !node.hidden) {
          elements.push({
            path,
            depth,
            parentPath: path === '/' ? null : parentPath(path),
            role: node.role || 'unknown',
            label,
            value: node.value || '',
            identifier: node.identifier || '',
            title: node.title || '',
            childCount: (node.children || []).length,
            frame
          });
        }
        (node.children || []).forEach((child, i) => {
          const childPath = path === '/' ? `/children/${i}` : `${path}/children/${i}`;
          walk(child, childPath, depth + 1);
        });
      };
      walk(root, '/', 0);
      return { elements, rootFrame };
    } catch {
      return { elements: [], rootFrame: null };
    }
  }

  function normalizeStoredReviewElements(snapshot) {
    const raw = Array.isArray(snapshot?.elements) ? snapshot.elements : [];
    const elements = raw.map(e => {
      const frame = normalizeFrame(e.frame);
      if (!frame) return null;
      return {
        path: e.axNodePath || '/',
        depth: Number(e.depth || 0),
        role: e.role || 'unknown',
        label: e.label || e.title || e.value || e.identifier || e.role || e.axNodePath,
        value: e.value || '',
        identifier: e.identifier || '',
        title: e.title || '',
        parentPath: e.parentPath || parentPath(e.axNodePath || '/'),
        childCount: Number(e.childCount || 0),
        frame
      };
    }).filter(Boolean);
    const rootFrame = elements.find(e => e.path === '/')?.frame || elements[0]?.frame || null;
    return { elements, rootFrame };
  }

  function normalizeFrame(frame) {
    if (!frame || typeof frame !== 'object') return null;
    const x = Number(frame.x ?? frame.origin?.x);
    const y = Number(frame.y ?? frame.origin?.y);
    const width = Number(frame.width ?? frame.size?.width);
    const height = Number(frame.height ?? frame.size?.height);
    if (![x, y, width, height].every(Number.isFinite)) return null;
    return { x, y, width, height };
  }

  function elementKey(snapshotId, path) { return `${snapshotId}::${path}`; }
  function splitElementKey(key) {
    const idx = String(key || '').indexOf('::');
    if (idx < 0) return null;
    return { snapshotId: key.slice(0, idx), path: key.slice(idx + 2), frame: null };
  }

  function reviewFramePayload(frame) {
    if (!frame) return null;
    return {
      origin: { x: frame.x, y: frame.y },
      size: { width: frame.width, height: frame.height }
    };
  }

  function parentPath(path) {
    const p = String(path || '/');
    if (p === '/') return null;
    const idx = p.lastIndexOf('/children/');
    if (idx <= 0) return '/';
    return p.slice(0, idx) || '/';
  }

  async function buildElementContext(review, session, snapshot, element, elements) {
    const ancestors = elementAncestors(element, elements);
    return {
      snapshot,
      element,
      ancestors,
      comments: commentsFor(session, snapshot.id, element.path),
      componentHints: componentHints(element, ancestors),
      sourceReferences: await sourceReferences(review, element, ancestors)
    };
  }

  function commentsFor(session, snapshotId, path) {
    return (session.comments || []).filter(c =>
      c.snapshotId === snapshotId && (!path || c.axNodePath === path)
    );
  }

  function elementAncestors(element, elements) {
    const byPath = new Map(elements.map(e => [e.path, e]));
    const ancestors = [];
    let cursor = element.parentPath || parentPath(element.path);
    while (cursor) {
      const parent = byPath.get(cursor);
      if (parent) ancestors.unshift(parent);
      cursor = parent?.parentPath || parentPath(cursor);
      if (cursor === '/') {
        const root = byPath.get('/');
        if (root && !ancestors.includes(root)) ancestors.unshift(root);
        break;
      }
    }
    return ancestors;
  }

  function componentHints(element, ancestors) {
    const chain = [...ancestors, element].filter(Boolean);
    return chain.map(e => ({
      path: e.path,
      role: e.role,
      identifier: e.identifier || '',
      label: e.label || '',
      value: e.value || '',
      title: e.title || ''
    }));
  }

  async function sourceReferences(review, element, ancestors) {
    const terms = [];
    [...ancestors, element].filter(Boolean).forEach(e => {
      [e.identifier, e.label, e.title, e.value].filter(Boolean).forEach(value => {
        reviewSearchTerms(value).forEach(term => terms.push(term));
      });
    });
    const uniqueTerms = uniq(terms).slice(0, 8);
    const likelyProps = [
      'testID',
      'nativeID',
      'accessibilityIdentifier',
      'accessibilityLabel',
      'accessibilityRole',
      'accessibilityHint'
    ];
    const refs = {
      elementPath: element.path,
      role: element.role,
      likelyProps,
      terms: uniqueTerms,
      searchCommands: uniqueTerms.map(term =>
        `rg -n ${JSON.stringify(term)} app src components screens packages --glob '*.{js,jsx,ts,tsx}'`
      ),
      matches: []
    };
    const root = String(review?.sourceRoot || '').trim();
    if (root && uniqueTerms.length) {
      try {
        const res = await fetch('/reviews/source-search', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ root, terms: uniqueTerms, maxMatches: 12 })
        });
        if (res.ok) {
          const json = await res.json();
          refs.root = json.root;
          refs.matches = Array.isArray(json.matches) ? json.matches : [];
        }
      } catch (error) {
        refs.error = String(error?.message || error);
      }
    }
    return refs;
  }

  function reviewSearchTerms(value) {
    const raw = String(value || '').trim();
    if (!raw) return [];
    const terms = [];
    if (raw.length <= 120) terms.push(raw);
    raw.split(/[,·•|;]|\s+[–—-]\s+|\n/)
      .map(s => s.replace(/^Ask:\s*/i, '').replace(/^["“”']|["“”']$/g, '').trim())
      .filter(s => s.length >= 3 && s.length <= 80)
      .forEach(s => terms.push(s));
    return uniq(terms)
      .filter(term => !['Voyage', 'AXGenericElement', 'AXApplication'].includes(term));
  }

  function formatReviewSelectionContext(session, selection, bundle) {
    const lines = [];
    lines.push(`# Review handoff: ${session.name}`);
    lines.push(`Session: ${session.id}`);
    lines.push(`Farm: http://${location.host}/farm`);
    if (bundle) {
      lines.push(`Bundle JSON: http://${location.host}/reviews/${session.id}/artifact?path=${encodeURIComponent(bundle.jsonPath)}`);
      lines.push(`Bundle brief: http://${location.host}/reviews/${session.id}/artifact?path=${encodeURIComponent(bundle.markdownPath)}`);
    }
    lines.push('');
    lines.push(`Selected elements: ${selection.filter(x => x.element).length}`);
    lines.push('');
    selection.forEach((ctx, index) => {
      const snap = ctx.snapshot;
      const el = ctx.element;
      lines.push(`## ${index + 1}. ${el ? elementSummary(el) : 'Screen'} on ${snap.id}`);
      lines.push(`Snapshot: ${snap.id}`);
      lines.push(`Device: ${snap.udid}`);
      lines.push(`Screenshot: http://${location.host}/reviews/${session.id}/artifact?path=${encodeURIComponent(snap.screenshotPath)}`);
      lines.push(`AX artifact: http://${location.host}/reviews/${session.id}/artifact?path=${encodeURIComponent(snap.axPath)}`);
      if (el) {
        lines.push(`AX path: ${el.path}`);
        lines.push(`Frame: x=${round(el.frame.x)} y=${round(el.frame.y)} w=${round(el.frame.width)} h=${round(el.frame.height)}`);
        lines.push(`Role: ${el.role}`);
        if (el.identifier) lines.push(`Identifier: ${el.identifier}`);
        if (el.label) lines.push(`Label: ${el.label}`);
        if (el.value) lines.push(`Value: ${el.value}`);
        lines.push('');
        lines.push('Hierarchy / component context:');
        [...ctx.ancestors, el].forEach((node, depth) => {
          lines.push(`${'  '.repeat(depth)}- ${elementSummary(node)} (${node.path})`);
        });
        lines.push('');
        lines.push('React Native / Expo source references:');
        lines.push(`Likely props: ${ctx.sourceReferences.likelyProps.join(', ')}`);
        if (ctx.sourceReferences.terms.length) {
          lines.push(`Search terms: ${ctx.sourceReferences.terms.map(t => JSON.stringify(t)).join(', ')}`);
          if (ctx.sourceReferences.root) lines.push(`Source root: ${ctx.sourceReferences.root}`);
          if (ctx.sourceReferences.matches?.length) {
            lines.push('Source matches:');
            ctx.sourceReferences.matches.forEach(match => {
              lines.push(`- ${match.path}:${match.line} (${JSON.stringify(match.term)}) ${match.preview}`);
            });
          }
          ctx.sourceReferences.searchCommands.forEach(command => lines.push(`- ${command}`));
        } else {
          lines.push('- No stable identifier or label was captured for this element.');
        }
      }
      if (ctx.comments.length) {
        lines.push('');
        lines.push('Comments:');
        ctx.comments.forEach(c => lines.push(`- ${c.text}`));
      }
      lines.push('');
    });
    lines.push('```json');
    lines.push(JSON.stringify({
      session: { id: session.id, name: session.name },
      bundle: bundle || null,
      selection: selection.map(ctx => ({
        snapshotId: ctx.snapshot.id,
        udid: ctx.snapshot.udid,
        screenshotPath: ctx.snapshot.screenshotPath,
        axPath: ctx.snapshot.axPath,
        element: ctx.element,
        ancestors: ctx.ancestors,
        componentHints: ctx.componentHints,
        sourceReferences: ctx.sourceReferences,
        comments: ctx.comments
      }))
    }, null, 2));
    lines.push('```');
    return lines.join('\n');
  }

  function elementSummary(e) {
    return [e.role, e.identifier, e.label || e.title || e.value].filter(Boolean).join(' · ') || e.path;
  }

  function round(n) { return Math.round(Number(n) * 100) / 100; }

  function uniq(xs) { return [...new Set(xs)]; }
  function byId(id) { return document.getElementById(id); }
  function cssEscape(s) { return (window.CSS?.escape ? CSS.escape(s) : s); }

  // Boot.
  window.FarmApp = FarmApp;
  document.addEventListener('DOMContentLoaded', () => {
    const app = new FarmApp();
    window.__farmApp = app;
    app.boot();
  });
})();
