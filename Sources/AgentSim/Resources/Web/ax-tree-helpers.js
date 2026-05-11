// ax-tree-helpers.js — shared AX-node tree utilities used by both
// `sim-ax-inspector.js` (live overlay) and `review-ax-tree.js`
// (post-mortem inspector). Pure functions on plain AXNode JSON
// (Domain shape: `{role, label, frame, hidden, children: [...]}`).
//
// window.AxTreeHelpers exposes:
//   - stampPaths(root)         — assign `_path` to every node in place
//   - forEachVisible(root, fn) — depth-first walk skipping hidden
//   - findByPath(root, path)   — resolve `/children/0/...` to node
//   - hitTest(root, x, y)      — deepest non-hidden node containing point

(function () {
  'use strict';

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

  function forEachVisible(node, fn) {
    if (!node || node.hidden === true) return;
    fn(node);
    const kids = node.children || [];
    for (let i = 0; i < kids.length; i++) forEachVisible(kids[i], fn);
  }

  function findByPath(root, path) {
    if (!root) return null;
    if (!path || path === '/') return root;
    const parts = String(path).split('/').filter(Boolean);
    let node = root;
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

  function hitTest(node, x, y) {
    if (!node || node.hidden === true) return null;
    const f = node.frame;
    if (!f) return null;
    if (!(x >= f.x && y >= f.y && x < f.x + f.width && y < f.y + f.height)) return null;
    const kids = node.children || [];
    for (let i = kids.length - 1; i >= 0; i--) {
      const m = hitTest(kids[i], x, y);
      if (m) return m;
    }
    return node;
  }

  window.AxTreeHelpers = { stampPaths, forEachVisible, findByPath, hitTest };
})();
