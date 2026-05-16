// sim-ax-inspector.js — accessibility-tree overlay for the live
// stream view. Hangs `window.AXInspector` on the global; sim-stream.js
// wires one instance per active stream.
//
// Behaviour:
//   - The overlay activates when the caller calls `enable()` (sidebar
//     mode renders an inline toggle in `host`; focus mode drives this
//     from a toolbar button).
//   - When enabled, the AX tree is fetched once and re-fetched on
//     every fresh hover (mouseenter on the screen) and on click,
//     so the user sees a fresh snapshot per inspection without
//     paying for a polling loop.
//   - Hover hit-tests the cached tree client-side (Domain `AXNode`
//     ships frames in the same device-point space as gestures), and
//     paints a translucent box + tooltip over the hovered node.
//   - Clicking locks the selection. The inspector renders the
//     selection into `host` (if provided) and fires `onSelect(node)`
//     so callers without an inline host (focus mode) can show it
//     elsewhere — e.g. a slide-up sheet.
//
// While enabled, the overlay swallows mouse events so taps don't
// bleed into the gesture pipeline. While disabled, the overlay is
// `pointer-events:none` and the underlying gesture surface behaves
// exactly as before.
//
// Wire dependency:
//   - Sends   `{"type":"describe_ui"}`    over the stream WS.
//   - Receives `{"type":"describe_ui_result","ok":true,"tree":…}`
//     from same WS (or `{"ok":false,"error":…}` on failure).
// AX tree shape mirrors `Domain/Accessibility/AXNode.swift`.

(function () {
  'use strict';

  // --- Pure helpers -------------------------------------------------

  // Deepest descendant whose frame contains (x, y). Mirrors
  // `AXNode.hitTest` in Domain so the JS overlay and the Swift
  // CLI/programmatic API pick the same element. `hidden === true`
  // nodes are skipped entirely — they're not interactable from the
  // user's perspective.
  function hitTest(node, x, y) {
    if (!node || node.hidden === true) return null;
    if (!nodeContains(node, x, y)) return null;
    const kids = node.children || [];
    for (let i = kids.length - 1; i >= 0; i--) {
      const m = hitTest(kids[i], x, y);
      if (m) return m;
    }
    return node;
  }

  function nodeContains(n, x, y) {
    const f = n && n.frame;
    if (!f) return false;
    return x >= f.x && y >= f.y && x < f.x + f.width && y < f.y + f.height;
  }

  function escapeHTML(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
    })[c]);
  }

  // Render the selection details + action row into an arbitrary host
  // element. Exposed as a static so both the sidebar mode (in-card)
  // and the focus mode (in-sheet) can reuse the same markup.
  //
  // `ctx`: { send, getDeviceSize }
  //   - send:          (payload) => void  — dispatch a JSON envelope on the WS
  //   - getDeviceSize: () => { w, h }     — device-point dims for `tap`
  //
  // The button row is laid out as:
  //   [ Copy id ] [ Copy JSON ]
  //   [        Tap (cx, cy)        ]
  // The 2-up + full-width pattern keeps every button readable in a
  // narrow ~220px sidebar without text wrapping; Tap is the primary
  // action so it gets the prominent full-width slot.
  function renderSelectionInto(host, node, ctx) {
    if (!host) return;
    if (!node) {
      host.style.display = 'none';
      host.innerHTML = '';
      return;
    }
    const cx = node.frame.x + node.frame.width  / 2;
    const cy = node.frame.y + node.frame.height / 2;
    const row = (k, v) => v == null || v === '' ? ''
      : '<div><span style="color:var(--text-muted);display:inline-block;width:60px">' +
        k + '</span>' + escapeHTML(v) + '</div>';

    host.style.display = '';
    host.innerHTML =
      '<div style="font-size:11px;line-height:1.45;' +
        'font-family:ui-monospace,SFMono-Regular,Menlo,monospace">' +
        row('role',  node.role) +
        row('label', node.label) +
        row('id',    node.identifier) +
        row('value', node.value) +
        '<div><span style="color:var(--text-muted);display:inline-block;width:60px">frame</span>' +
          node.frame.x.toFixed(0) + ',' + node.frame.y.toFixed(0) + ' ' +
          node.frame.width.toFixed(0) + '×' + node.frame.height.toFixed(0) +
        '</div>' +
      '</div>' +
      '<div style="display:grid;grid-template-columns:1fr 1fr;gap:6px;margin-top:8px">' +
        '<button class="btn btn-sm" data-act="copy-id"' +
          (node.identifier ? '' : ' disabled') +
          ' style="white-space:nowrap">Copy id</button>' +
        '<button class="btn btn-sm" data-act="copy-json"' +
          ' style="white-space:nowrap">Copy JSON</button>' +
      '</div>' +
      '<button class="btn btn-sm btn-primary" data-act="tap"' +
        ' style="width:100%;margin-top:6px;white-space:nowrap">' +
        'Tap (' + cx.toFixed(0) + ', ' + cy.toFixed(0) + ')' +
      '</button>';

    const copyId = host.querySelector('[data-act="copy-id"]');
    if (copyId && node.identifier) {
      copyId.addEventListener('click', () => {
        navigator.clipboard?.writeText(node.identifier);
      });
    }
    host.querySelector('[data-act="copy-json"]')
      .addEventListener('click', () => {
        navigator.clipboard?.writeText(JSON.stringify(node, null, 2));
      });
    host.querySelector('[data-act="tap"]')
      .addEventListener('click', () => {
        // Wire shape matches GestureRegistry's `tap`: device-point
        // coordinates plus the device-point screen size.
        const sz = (ctx.getDeviceSize && ctx.getDeviceSize()) || { w: 0, h: 0 };
        ctx.send({
          type: 'tap',
          x: cx, y: cy, width: sz.w, height: sz.h,
        });
      });
  }

  // --- AXInspector --------------------------------------------------

  // Walk the tree once and stamp `_path` (and `_pathParts` for sorting)
  // onto every node. `_path` is the JSON-pointer-style string callers
  // hand to `POST /reviews/:id/tasks` as `axNodePath`. The root is `/`.
  function stampPaths(root) {
    function walk(n, path) {
      if (!n) return;
      n._path = path || '/';
      const kids = n.children || [];
      for (let i = 0; i < kids.length; i++) {
        walk(kids[i], (path === '/' ? '' : path) + '/children/' + i);
      }
    }
    walk(root, '/');
  }

  // Walk all visible (non-hidden) nodes; yields each node once.
  function forEachVisible(node, fn) {
    if (!node || node.hidden === true) return;
    fn(node);
    const kids = node.children || [];
    for (let i = 0; i < kids.length; i++) forEachVisible(kids[i], fn);
  }

  // Geometry helpers used by brush + rectangle tools. Mirror the
  // half-open `[origin, origin+size)` intersection convention in
  // `ReviewMarkupHitTest.swift` (Domain) — same algorithm, two
  // languages.

  function intersectsAB(rect, frame) {
    const aMinX = rect.x, aMaxX = rect.x + rect.w;
    const aMinY = rect.y, aMaxY = rect.y + rect.h;
    const bMinX = frame.x, bMaxX = frame.x + frame.width;
    const bMinY = frame.y, bMaxY = frame.y + frame.height;
    return aMinX < bMaxX && bMinX < aMaxX
        && aMinY < bMaxY && bMinY < aMaxY;
  }

  function containsFP(frame, p) {
    const minX = frame.x;
    const minY = frame.y;
    const maxX = minX + frame.width;
    const maxY = minY + frame.height;
    return p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY;
  }

  class AXInspector {
    constructor(opts) {
      this.host           = opts.host || null;       // optional sidebar mount
      this.screenArea     = opts.screenArea;         // overlay parent (already position:absolute)
      this.send           = opts.send;               // (payload) => void  — JSON over stream WS
      this.getDeviceSize  = opts.getDeviceSize;      // () => { w, h }     — device-point dims
      this.onSelect            = opts.onSelect            || null; // (node | null) => void
      this.onSelectionChange   = opts.onSelectionChange   || null; // (Array<{path,node}>) => void
      this.onStatus            = opts.onStatus            || null; // (text)         => void
      this.onEnableChange      = opts.onEnableChange      || null; // (enabled: bool) => void

      this.tree = null;
      this.hover = null;
      this.selected = null;                    // inspect-mode: single node
      this.selections = new Map();             // select-mode: path → node
      this.selectionMode = 'inspect';          // 'inspect' | 'select'
      this.enabled = false;

      if (this.host) this._buildSidebar();
      this._buildOverlay();

      // Debug handle for end-to-end testing (agent-browser). Last
      // constructed inspector wins — fine for any practical workflow
      // since pages mount one at a time.
      try { window.__agentSimAXInspector = this; } catch (_) { /* ignore */ }
    }

    setSelectionMode(mode) {
      const allowed = ['inspect', 'select', 'brush', 'rectangle'];
      const m = allowed.includes(mode) ? mode : 'inspect';
      if (m === this.selectionMode) return;
      this.selectionMode = m;
      // Switching modes clears the cross-mode state so the user
      // doesn't see stale picks.
      this.selected = null;
      this.selections.clear();
      this._activeStroke = null;
      this._activeRect = null;
      this._dragging = false;
      this._updateToolButtonStates();
      this._renderInfo();
      this._draw();
      this._fireSelectionChange();
      if (this.onSelect) this.onSelect(null);
    }

    _updateToolButtonStates() {
      if (!this.toolButtonEls) return;
      this.toolButtonEls.forEach((btn) => {
        const active = btn.dataset.mode === this.selectionMode;
        btn.dataset.active = active ? '1' : '0';
        btn.style.background = active ? 'var(--accent, #2563eb)' : 'transparent';
        btn.style.color      = active ? '#fff' : 'inherit';
      });
    }

    getSelections() {
      const out = [];
      this.selections.forEach((node, path) => out.push({ path, node }));
      return out;
    }

    clearSelections() {
      if (!this.selections.size) return;
      this.selections.clear();
      this._draw();
      this._fireSelectionChange();
    }

    removeSelection(path) {
      if (!this.selections.delete(path)) return;
      this._draw();
      this._fireSelectionChange();
    }

    _fireSelectionChange() {
      if (this.onSelectionChange) this.onSelectionChange(this.getSelections());
    }

    /// Public: dispatch a stream-WS text envelope. Returns `true`
    /// when the envelope was consumed (so StreamSession's onText
    /// hook can short-circuit the decoder).
    handleEnvelope(env) {
      if (!env || env.type !== 'describe_ui_result') return false;
      if (env.ok && env.tree) {
        this.tree = env.tree;
        stampPaths(this.tree);
        // Re-resolve any persisted selections against the fresh tree
        // (positions and even the set of nodes can shift across
        // re-fetches). Drop selections whose path no longer exists.
        if (this.selections.size) {
          const next = new Map();
          this.selections.forEach((_, path) => {
            const node = this._findByPath(path);
            if (node) next.set(path, node);
          });
          this.selections = next;
          this._fireSelectionChange();
        }
        this._setStatus('');
      } else {
        this.tree = null;
        this._setStatus(env.error || 'no accessibility data');
      }
      this._draw();
      return true;
    }

    _findByPath(path) {
      if (!this.tree) return null;
      if (path === '/') return this.tree;
      let node = this.tree;
      const parts = path.split('/').filter(Boolean);
      for (let i = 0; i < parts.length; i += 2) {
        if (parts[i] !== 'children') return null;
        const idx = parseInt(parts[i + 1], 10);
        if (!Number.isFinite(idx)) return null;
        const kids = node.children || [];
        node = kids[idx];
        if (!node) return null;
      }
      return node;
    }

    enable() {
      if (this.enabled) return;
      this.enabled = true;
      if (this.toggleEl) this.toggleEl.checked = true;
      if (this.toolsEl)  this.toolsEl.style.display = 'flex';
      this._updateToolButtonStates();
      this.overlay.style.display = '';
      this.overlay.style.pointerEvents = 'auto';
      this._refresh();
      if (this.onEnableChange) this.onEnableChange(true);
    }

    disable() {
      if (!this.enabled) return;
      this.enabled = false;
      if (this.toggleEl) this.toggleEl.checked = false;
      if (this.toolsEl)  this.toolsEl.style.display = 'none';
      this.overlay.style.pointerEvents = 'none';
      this.overlay.style.display = 'none';
      this.tree = null;
      this.hover = null;
      this.selected = null;
      const hadSelections = this.selections.size > 0;
      this.selections.clear();
      this._activeStroke = null;
      this._activeRect = null;
      this._dragging = false;
      this._setStatus('');
      this._renderInfo();
      this._draw();
      if (this.onSelect) this.onSelect(null);
      if (hadSelections) this._fireSelectionChange();
      if (this.onEnableChange) this.onEnableChange(false);
    }

    isEnabled() { return this.enabled; }

    detach() {
      try { this.disable(); } catch { /* ignore */ }
      if (this._onResize) {
        window.removeEventListener('resize', this._onResize);
        this._onResize = null;
      }
      if (this.overlay && this.overlay.parentNode) {
        this.overlay.parentNode.removeChild(this.overlay);
      }
      if (this.host) this.host.innerHTML = '';
    }

    // --- internal: sidebar UI -----------------------------------

    _buildSidebar() {
      this.host.innerHTML =
        '<label style="display:flex;align-items:center;gap:8px;font-size:11px;cursor:pointer;user-select:none">' +
          '<input type="checkbox" data-role="toggle">' +
          '<span>Inspect (hover)</span>' +
          '<span data-role="status" style="margin-left:auto;color:var(--text-muted);font-size:10px"></span>' +
        '</label>' +
        '<div data-role="tools" style="margin-top:8px;display:none;gap:4px">' +
          '<button data-mode="select"    type="button" style="flex:1;padding:4px 6px;border:1px solid var(--border,#cbd5e1);border-radius:4px;font-size:11px;cursor:pointer">Select</button>' +
          '<button data-mode="brush"     type="button" style="flex:1;padding:4px 6px;border:1px solid var(--border,#cbd5e1);border-radius:4px;font-size:11px;cursor:pointer">Brush</button>' +
          '<button data-mode="rectangle" type="button" style="flex:1;padding:4px 6px;border:1px solid var(--border,#cbd5e1);border-radius:4px;font-size:11px;cursor:pointer">Rect</button>' +
        '</div>' +
        '<div data-role="info" style="margin-top:8px;display:none"></div>';
      this.toggleEl  = this.host.querySelector('[data-role="toggle"]');
      this.statusEl  = this.host.querySelector('[data-role="status"]');
      this.infoEl    = this.host.querySelector('[data-role="info"]');
      this.toolsEl   = this.host.querySelector('[data-role="tools"]');
      this.toolButtonEls = Array.from(this.toolsEl.querySelectorAll('button[data-mode]'));
      this.toolButtonEls.forEach((btn) => {
        btn.addEventListener('click', () => this.setSelectionMode(btn.dataset.mode));
      });
      this.toggleEl.addEventListener('change', () => {
        if (this.toggleEl.checked) this.enable(); else this.disable();
      });
    }

    _setStatus(text) {
      const t = text || '';
      if (this.statusEl) this.statusEl.textContent = t;
      if (this.onStatus) this.onStatus(t);
    }

    // --- internal: overlay canvas + mouse handlers --------------

    _buildOverlay() {
      const ov = document.createElement('canvas');
      ov.style.cssText =
        'position:absolute;inset:0;pointer-events:none;display:none;' +
        'z-index:5;touch-action:none';
      this.overlay = ov;
      this.screenArea.appendChild(ov);
      this._sizeOverlay();

      this._onResize = () => { this._sizeOverlay(); this._draw(); };
      window.addEventListener('resize', this._onResize);

      // Bind once — handlers no-op when disabled (events don't fire
      // anyway because pointer-events:none in that state, but we
      // guard defensively).
      ov.addEventListener('mouseenter', () => {
        if (this.enabled) this._refresh();
      });
      ov.addEventListener('mousemove', (e) => {
        if (!this.enabled) return;
        if (this._dragging) this._handleDragMove(e);
        else this._handleMove(e);
      });
      ov.addEventListener('mouseleave', () => {
        if (!this.enabled) return;
        this.hover = null;
        this._draw();
      });
      ov.addEventListener('mousedown', (e) => {
        if (!this.enabled) return;
        e.preventDefault();
        e.stopPropagation();
        if (this.selectionMode === 'brush' || this.selectionMode === 'rectangle') {
          this._handleDragStart(e);
        }
      });
      ov.addEventListener('mouseup', (e) => {
        if (!this.enabled || !this._dragging) return;
        e.preventDefault();
        e.stopPropagation();
        this._handleDragEnd(e);
      });
      ov.addEventListener('click', (e) => {
        if (!this.enabled) return;
        // Brush + rectangle handle their submit on mouseup; click is
        // the legacy single-pick path for select / inspect.
        if (this.selectionMode === 'brush' || this.selectionMode === 'rectangle') return;
        e.preventDefault();
        e.stopPropagation();
        this._handleClick(e);
      });
      // Right-click on a selected element removes it from the set
      // (only meaningful in select-mode).
      ov.addEventListener('contextmenu', (e) => {
        if (!this.enabled) return;
        const multiMode = this.selectionMode === 'select'
                       || this.selectionMode === 'brush'
                       || this.selectionMode === 'rectangle';
        if (!multiMode) return;
        e.preventDefault();
        e.stopPropagation();
        if (this.hover && this.hover._path && this.selections.has(this.hover._path)) {
          this.removeSelection(this.hover._path);
        }
      });

      // Touch path (phones / tablets). The mouse handlers above
      // never fire on a touch-only device, and the browser's
      // synthetic click arrives with no preceding hover (touch has
      // no hover state), so picks would target nothing. We drive
      // hover + pick straight from the touch points. preventDefault
      // + stopPropagation keep the tap from bubbling to the
      // TouchGestureSource bound on `screenArea` underneath — while
      // the inspector is enabled the overlay OWNS the touch (select
      // an element); while disabled it's pointer-events:none and the
      // simulator gets the touch (drive it normally).
      const touchPoint = (t) => ({
        clientX: t.clientX, clientY: t.clientY,
        shiftKey: false, metaKey: false, ctrlKey: false,
        preventDefault() {}, stopPropagation() {},
      });
      const isDragMode = () =>
        this.selectionMode === 'brush' || this.selectionMode === 'rectangle';
      ov.addEventListener('touchstart', (e) => {
        if (!this.enabled) return;
        e.preventDefault(); e.stopPropagation();
        if (!this.tree) this._refresh();
        const t = e.touches[0]; if (!t) return;
        const pt = touchPoint(t);
        if (isDragMode()) this._handleDragStart(pt);
        else this._handleMove(pt);   // highlight element under finger
      }, { passive: false });
      ov.addEventListener('touchmove', (e) => {
        if (!this.enabled) return;
        e.preventDefault(); e.stopPropagation();
        const t = e.touches[0]; if (!t) return;
        const pt = touchPoint(t);
        if (this._dragging) this._handleDragMove(pt);
        else this._handleMove(pt);
      }, { passive: false });
      ov.addEventListener('touchend', (e) => {
        if (!this.enabled) return;
        e.preventDefault(); e.stopPropagation();
        const t = e.changedTouches[0];
        const pt = t ? touchPoint(t) : null;
        if (isDragMode()) {
          if (pt) this._handleDragEnd(pt);
        } else {
          if (pt) this._handleMove(pt);   // lift point is the pick
          this._handleClick(pt || { shiftKey: false });
        }
      }, { passive: false });
      ov.addEventListener('touchcancel', (e) => {
        if (!this.enabled) return;
        e.preventDefault(); e.stopPropagation();
        this._dragging = false;
        this._activeStroke = null;
        this._activeRect = null;
        this._draw();
      }, { passive: false });
    }

    _sizeOverlay() {
      const r = this.screenArea.getBoundingClientRect();
      const dpr = window.devicePixelRatio || 1;
      this.overlay.width  = Math.max(1, Math.round(r.width  * dpr));
      this.overlay.height = Math.max(1, Math.round(r.height * dpr));
      this.overlay.style.width  = r.width + 'px';
      this.overlay.style.height = r.height + 'px';
    }

    // --- internal: events ---------------------------------------

    _refresh() {
      if (!this.enabled) return;
      this._setStatus('fetching…');
      try { this.send({ type: 'describe_ui' }); }
      catch { this._setStatus('send failed'); }
    }

    _handleMove(e) {
      if (!this.tree) return;
      const dev = this._toDevicePoint(e);
      const hit = hitTest(this.tree, dev.x, dev.y);
      if (hit !== this.hover) {
        this.hover = hit;
        this._draw();
      }
    }

    // --- internal: brush / rectangle drag ----------------------

    _handleDragStart(e) {
      const p = this._toDevicePoint(e);
      const additive = !!(e && (e.shiftKey || e.metaKey || e.ctrlKey));
      if (!additive) this.selections.clear();
      this._dragging = true;
      if (this.selectionMode === 'brush') {
        this._activeStroke = [p];
        this._activeRect = null;
      } else {
        this._activeStroke = null;
        this._activeRect = { ax: p.x, ay: p.y, bx: p.x, by: p.y };
      }
      this._draw();
    }

    _handleDragMove(e) {
      const p = this._toDevicePoint(e);
      if (this.selectionMode === 'brush' && this._activeStroke) {
        // Down-sample: only push when we've moved at least 4 device-
        // points from the last sample. Keeps hit-test linear in the
        // visible stroke length, not the mouse-event count.
        const last = this._activeStroke[this._activeStroke.length - 1];
        if (Math.hypot(p.x - last.x, p.y - last.y) >= 4) {
          this._activeStroke.push(p);
        }
      } else if (this.selectionMode === 'rectangle' && this._activeRect) {
        this._activeRect.bx = p.x;
        this._activeRect.by = p.y;
      }
      this._draw();
    }

    _handleDragEnd(e) {
      const p = this._toDevicePoint(e);
      let hits = [];
      if (this.selectionMode === 'brush' && this._activeStroke) {
        if (this._activeStroke.length === 0 || this._activeStroke[this._activeStroke.length - 1] !== p) {
          this._activeStroke.push(p);
        }
        hits = this._hitTestBrush(this._activeStroke);
      } else if (this.selectionMode === 'rectangle' && this._activeRect) {
        this._activeRect.bx = p.x;
        this._activeRect.by = p.y;
        const rect = this._rectFromActive(this._activeRect);
        hits = this._hitTestRect(rect);
      }
      hits.forEach((node) => {
        if (!node._path) return;
        this.selections.set(node._path, node);
      });
      this._activeStroke = null;
      this._activeRect = null;
      this._dragging = false;
      this._draw();
      this._refresh();
      this._fireSelectionChange();
    }

    _rectFromActive(active) {
      const minX = Math.min(active.ax, active.bx);
      const minY = Math.min(active.ay, active.by);
      return {
        x: minX, y: minY,
        w: Math.abs(active.bx - active.ax),
        h: Math.abs(active.by - active.ay),
      };
    }

    /// Walks the AX tree and returns the nodes whose frames intersect
    /// `rect` (in device points). Mirrors `ReviewMarkupHitTest.rectangleHits`
    /// in Swift — same half-open intersection convention. Zero-area
    /// rect falls back to a single-point brush so a tiny drag selects
    /// just the element under the click.
    _hitTestRect(rect) {
      if (!this.tree) return [];
      if (rect.w === 0 && rect.h === 0) {
        return this._hitTestBrush([{ x: rect.x, y: rect.y }]);
      }
      const out = [];
      forEachVisible(this.tree, (n) => {
        if (!n.frame) return;
        if (intersectsAB(rect, n.frame)) out.push(n);
      });
      return out;
    }

    _hitTestBrush(points) {
      if (!this.tree || !points.length) return [];
      const seen = new Set();
      const out = [];
      forEachVisible(this.tree, (n) => {
        if (!n.frame) return;
        for (const p of points) {
          if (containsFP(n.frame, p)) {
            if (n._path && !seen.has(n._path)) {
              seen.add(n._path);
              out.push(n);
            }
            return;
          }
        }
      });
      return out;
    }

    _handleClick(e) {
      if (this.selectionMode === 'select') {
        if (!this.hover || !this.hover._path) return;
        const path = this.hover._path;
        const additive = !!(e && (e.shiftKey || e.metaKey || e.ctrlKey));
        if (additive) {
          if (this.selections.has(path)) this.selections.delete(path);
          else this.selections.set(path, this.hover);
        } else {
          this.selections.clear();
          this.selections.set(path, this.hover);
        }
        this._draw();
        this._refresh();
        this._fireSelectionChange();
        return;
      }
      // inspect-mode (legacy single-pick)
      this.selected = this.hover;
      this._renderInfo();
      this._draw();
      this._refresh();
      if (this.onSelect) this.onSelect(this.selected);
    }

    _renderInfo() {
      if (this.infoEl) {
        renderSelectionInto(this.infoEl, this.selected, {
          send: this.send,
          getDeviceSize: this.getDeviceSize,
        });
      }
    }

    _toDevicePoint(e) {
      const r = this.screenArea.getBoundingClientRect();
      const fx = (e.clientX - r.left) / Math.max(1, r.width);
      const fy = (e.clientY - r.top)  / Math.max(1, r.height);
      const sz = this.getDeviceSize() || { w: 0, h: 0 };
      return { x: fx * sz.w, y: fy * sz.h };
    }

    // --- internal: rendering ------------------------------------

    _draw() {
      this._sizeOverlay();
      const ctx = this.overlay.getContext('2d');
      ctx.clearRect(0, 0, this.overlay.width, this.overlay.height);
      if (!this.enabled) return;

      const sz = this.getDeviceSize() || { w: 0, h: 0 };
      if (!sz.w || !sz.h) return;
      const sx = this.overlay.width  / sz.w;
      const sy = this.overlay.height / sz.h;

      const drawNode = (n, stroke, fill, lw) => {
        if (!n || !n.frame) return;
        const x = n.frame.x * sx, y = n.frame.y * sy;
        const w = n.frame.width  * sx;
        const h = n.frame.height * sy;
        ctx.lineWidth = lw;
        ctx.strokeStyle = stroke;
        if (fill) {
          ctx.fillStyle = fill;
          ctx.fillRect(x, y, w, h);
        }
        ctx.strokeRect(x, y, w, h);
      };

      // Hybrid: dim outline on every visible node when in any
      // multi-selection mode (select / brush / rectangle), so the
      // user can see the full hit-map at a glance without
      // hover-discovery.
      const multiMode = this.selectionMode === 'select'
                     || this.selectionMode === 'brush'
                     || this.selectionMode === 'rectangle';
      if (multiMode && this.tree) {
        ctx.lineWidth = 0.5;
        ctx.strokeStyle = 'rgba(15, 23, 42, 0.35)';
        forEachVisible(this.tree, (n) => {
          if (!n.frame || !n.frame.width || !n.frame.height) return;
          ctx.strokeRect(
            n.frame.x * sx, n.frame.y * sy,
            n.frame.width * sx, n.frame.height * sy,
          );
        });
      }

      // Bright selections (multi-select layer) — red, slightly opaque
      // fill so overlapping siblings stack readably.
      if (this.selections.size) {
        this.selections.forEach((node) => {
          drawNode(node, 'rgba(220, 38, 38, 0.95)', 'rgba(220, 38, 38, 0.10)', 2);
        });
      }
      // Single-selected (inspect-mode legacy path).
      if (this.selected && !this.selections.size) {
        drawNode(this.selected, 'rgba(220, 38, 38, 0.95)', 'rgba(220, 38, 38, 0.10)', 2);
      }
      // Hover always paints last so it stays visible above selections.
      drawNode(this.hover, 'rgba(37, 99, 235, 0.95)', 'rgba(37, 99, 235, 0.12)', 2);

      // In-progress brush stroke / rectangle drag. Render last so the
      // drag preview sits above the static element outlines.
      if (this._activeStroke && this._activeStroke.length > 1) {
        ctx.lineWidth = 3;
        ctx.strokeStyle = 'rgba(37, 99, 235, 0.85)';
        ctx.lineCap = 'round';
        ctx.lineJoin = 'round';
        ctx.beginPath();
        ctx.moveTo(this._activeStroke[0].x * sx, this._activeStroke[0].y * sy);
        for (let i = 1; i < this._activeStroke.length; i++) {
          ctx.lineTo(this._activeStroke[i].x * sx, this._activeStroke[i].y * sy);
        }
        ctx.stroke();
      }
      if (this._activeRect) {
        const r = this._rectFromActive(this._activeRect);
        ctx.lineWidth = 2;
        ctx.strokeStyle = 'rgba(37, 99, 235, 0.85)';
        ctx.fillStyle   = 'rgba(37, 99, 235, 0.12)';
        ctx.fillRect(r.x * sx, r.y * sy, r.w * sx, r.h * sy);
        ctx.strokeRect(r.x * sx, r.y * sy, r.w * sx, r.h * sy);
      }

      if (this.hover) this._drawTooltip(ctx, this.hover, sx, sy);
    }

    _drawTooltip(ctx, n, sx, sy) {
      const label = n.label || n.identifier || n.title || n.role || '';
      if (!label) return;
      const text = (n.role ? '[' + n.role + '] ' : '') + label;
      const dpr = window.devicePixelRatio || 1;
      ctx.font = (11 * dpr) + 'px ui-monospace,SFMono-Regular,Menlo,monospace';
      const metrics = ctx.measureText(text);
      const padX = 6 * dpr, padY = 4 * dpr;
      const w = Math.min(this.overlay.width - 8 * dpr, metrics.width + padX * 2);
      const h = 16 * dpr + padY * 2 - 8 * dpr;
      let x = n.frame.x * sx;
      let y = n.frame.y * sy - h - 4 * dpr;
      if (y < 4 * dpr) y = (n.frame.y + n.frame.height) * sy + 4 * dpr;
      if (x + w > this.overlay.width) x = this.overlay.width - w - 4 * dpr;
      if (x < 4 * dpr) x = 4 * dpr;
      ctx.fillStyle = 'rgba(15,23,42,0.92)';
      ctx.fillRect(x, y, w, h);
      ctx.fillStyle = '#fff';
      ctx.textBaseline = 'middle';
      ctx.fillText(text, x + padX, y + h / 2);
    }
  }

  AXInspector.renderSelectionInto = renderSelectionInto;
  window.AXInspector = AXInspector;
})();
