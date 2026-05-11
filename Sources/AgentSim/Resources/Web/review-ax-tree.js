// review-ax-tree.js — interactive tree view of an AX snapshot, used
// by /reviews/:sid inspector. Replaces the old raw-JSON `<pre>` dump.
//
// Public API:
//   ReviewAxTree.mount({ host, tree, comments, onSelect, onHover })
//     → returns { setComments, setSelectedPath, highlight, unmount }
//
//   - host:     container element
//   - tree:     parsed AX root (with `_path` stamped via AxTreeHelpers.stampPaths)
//   - comments: ReviewElementComment[]  — used for 💬 N badges
//   - onSelect: (node|null) => void     — fired when a row is clicked
//   - onHover:  (node|null) => void     — fired on row hover (for snapshot bbox)

(function () {
  'use strict';

  function escapeHTML(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    })[c]);
  }

  function nodeLabel(n) {
    return n.label || n.identifier || n.title || n.value || '';
  }

  function mount(opts) {
    const host = opts.host;
    if (!host) return { setComments(){}, setSelectedPath(){}, highlight(){}, unmount(){} };
    let tree = opts.tree;
    let comments = opts.comments || [];
    let selectedPath = null;
    const onSelect = opts.onSelect;
    const onHover  = opts.onHover;

    // Build per-path comment count for badge rendering.
    function commentMap() {
      const m = new Map();
      comments.forEach((c) => {
        if (!c || !c.axNodePath) return;
        m.set(c.axNodePath, (m.get(c.axNodePath) || 0) + 1);
      });
      return m;
    }

    function render() {
      if (!tree) {
        host.innerHTML = '<div style="padding:8px;color:#94a3b8;font-style:italic;font-size:11px">No accessibility data.</div>';
        return;
      }
      const counts = commentMap();
      const lines = [];

      function emit(n, depth) {
        if (!n) return;
        const role = n.role || 'AX?';
        const lbl = nodeLabel(n);
        const path = n._path || '';
        const count = counts.get(path) || 0;
        const kids = n.children || [];
        const expanded = depth < 2 || count > 0 || selectedPath && selectedPath.startsWith(path);
        const chevron = kids.length
          ? `<span data-role="chevron" data-state="${expanded ? 'open' : 'closed'}" style="cursor:pointer;display:inline-block;width:12px;color:#94a3b8">${expanded ? '▾' : '▸'}</span>`
          : '<span style="display:inline-block;width:12px"></span>';
        const dim = n.hidden ? 'opacity:0.45;' : '';
        const active = path === selectedPath ? 'background:#fef3c7;border-left:2px solid #b45309;' : 'border-left:2px solid transparent;';
        const badge = count
          ? `<span style="background:#fde68a;color:#92400e;padding:0 5px;border-radius:999px;font-size:10px;margin-left:auto">💬 ${count}</span>`
          : '';
        lines.push(
          `<div class="ax-tree-row" data-path="${escapeHTML(path)}"` +
          ` style="display:flex;align-items:center;gap:6px;padding:2px 6px 2px ${4 + depth * 12}px;font:11px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;cursor:pointer;${active}${dim}">` +
            chevron +
            `<span style="color:#2563eb">[${escapeHTML(role)}]</span>` +
            (lbl ? `<span style="color:#0f172a;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${escapeHTML(path)}">${escapeHTML(lbl)}</span>` : '') +
            badge +
          '</div>'
        );
        if (expanded) {
          for (let i = 0; i < kids.length; i++) emit(kids[i], depth + 1);
        }
      }
      emit(tree, 0);

      host.innerHTML = lines.join('') ||
        '<div style="padding:8px;color:#94a3b8;font-style:italic;font-size:11px">Empty tree.</div>';

      host.querySelectorAll('.ax-tree-row').forEach((row) => {
        const path = row.dataset.path;
        row.addEventListener('click', (e) => {
          // Chevron click toggles expansion only.
          const tgt = e.target;
          if (tgt && tgt.dataset && tgt.dataset.role === 'chevron') {
            // Map state by inverting selectedPath proximity is too
            // coarse; force expanded-by-default for clicked node by
            // selecting it (selectedPath.startsWith(path) → expanded).
            // Toggle behaviour: clear selection if already on this path.
            if (selectedPath && selectedPath.startsWith(path)) selectedPath = null;
            else selectedPath = path;
            render();
            return;
          }
          selectedPath = path;
          render();
          const node = findNode(path);
          if (onSelect) onSelect(node);
        });
        row.addEventListener('mouseenter', () => {
          if (onHover) onHover(findNode(path));
        });
        row.addEventListener('mouseleave', () => {
          if (onHover) onHover(null);
        });
      });
    }

    function findNode(path) {
      const helpers = window.AxTreeHelpers;
      if (!helpers || !tree) return null;
      return helpers.findByPath(tree, path);
    }

    render();

    return {
      setComments(next) { comments = next || []; render(); },
      setSelectedPath(path) {
        selectedPath = path || null;
        render();
        // Scroll the selected row into view if it's offscreen.
        const row = host.querySelector('.ax-tree-row[data-path="' + (path || '').replace(/"/g, '\\"') + '"]');
        if (row) row.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
      },
      highlight(path) { this.setSelectedPath(path); },
      unmount() { host.innerHTML = ''; },
    };
  }

  window.ReviewAxTree = { mount };
})();
