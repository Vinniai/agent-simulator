// sim-activity.js — Activity Monitor dock for the Review queue.
// Subscribes to WS /review-tasks/stream?sessionId=<sid> and renders
// the live task list with status pills, agent, age, and a comment
// rollup. Auto-reconnects on socket close.
//
// Public API:
//   SimActivity.mount({ host, getSession })
//     → returns { unmount, setSession }
//
//   - host:       parent element to render into
//   - getSession: () => Promise<sessionId>  — used by the "Start session" empty state
//
// Updates filter via internal state; click on a row opens the review
// session in a new tab.

(function () {
  'use strict';

  function escapeHTML(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({
      '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
    })[c]);
  }

  const STATUS_PILL = {
    open:            { bg: '#e2e8f0', fg: '#1e293b', label: 'open'    },
    claimed:         { bg: '#fde68a', fg: '#854d0e', label: 'claimed' },
    inProgress:      { bg: '#fde68a', fg: '#854d0e', label: 'in progress' },
    readyForVerify:  { bg: '#dbeafe', fg: '#1e3a8a', label: 'verify'  },
    verified:        { bg: '#dcfce7', fg: '#166534', label: 'verified' },
    failed:          { bg: '#fee2e2', fg: '#991b1b', label: 'failed'  },
  };

  function pill(status) {
    const s = STATUS_PILL[status] || { bg: '#e2e8f0', fg: '#1e293b', label: status || '?' };
    return '<span style="background:' + s.bg + ';color:' + s.fg + ';' +
      'padding:1px 7px;border-radius:999px;font-size:10px;font-weight:600;text-transform:uppercase;letter-spacing:0.3px">' +
      escapeHTML(s.label) +
    '</span>';
  }

  function timeAgo(iso) {
    if (!iso) return '';
    const ms = Date.now() - new Date(iso).getTime();
    if (!Number.isFinite(ms) || ms < 0) return '';
    const m = Math.round(ms / 60000);
    if (m < 1) return 'just now';
    if (m < 60) return m + 'm';
    const h = Math.round(m / 60);
    if (h < 24) return h + 'h';
    const d = Math.round(h / 24);
    return d + 'd';
  }

  // Subscription is now delegated to ReviewTasksStream (shared with
  // review.js so /reviews/:sid stays live too). This file only owns
  // the rendering.

  function commentCount(task) {
    if (!task || !task.elements) return 0;
    return task.elements.filter((el) => el && el.commentText && el.commentText.trim()).length;
  }

  function mount(opts) {
    const host = opts.host;
    const getSession = opts.getSession;
    if (!host) return { unmount(){}, setSession(){} };

    host.innerHTML =
      '<div style="display:flex;flex-direction:column;height:100%;background:#fff;border-left:1px solid #e2e8f0;font:12px -apple-system,BlinkMacSystemFont,SF Pro Text,sans-serif;color:#0f172a">' +
        '<div style="padding:10px 12px;border-bottom:1px solid #e2e8f0;display:flex;align-items:center;gap:6px">' +
          '<strong style="font-size:13px">Activity</strong>' +
          '<label style="margin-left:auto;display:flex;align-items:center;gap:5px;cursor:pointer;user-select:none;font-size:11px">' +
            '<input type="checkbox" data-role="select-toggle">' +
            '<span>Select</span>' +
          '</label>' +
        '</div>' +
        '<div data-role="filters" style="display:flex;flex-wrap:wrap;gap:4px;padding:8px 10px;border-bottom:1px solid #e2e8f0"></div>' +
        '<div data-role="status" style="padding:0 12px;font-size:10px;color:#64748b;min-height:14px"></div>' +
        '<div data-role="list" style="flex:1;overflow:auto;padding:6px 8px"></div>' +
      '</div>';

    const filtersEl = host.querySelector('[data-role="filters"]');
    const statusEl  = host.querySelector('[data-role="status"]');
    const listEl    = host.querySelector('[data-role="list"]');
    const toggleEl  = host.querySelector('[data-role="select-toggle"]');

    const FILTERS = [
      { key: 'all',            label: 'All' },
      { key: 'open',           label: 'Open' },
      { key: 'claimed',        label: 'In progress' },
      { key: 'readyForVerify', label: 'Verify' },
      { key: 'verified',       label: 'Verified' },
      { key: 'failed',         label: 'Failed' },
    ];
    let activeFilter = 'all';
    let tasksByID = new Map();
    let sessionId = null;
    let stream = null;
    let unmounted = false;
    let onSelectToggle = null;

    function renderFilters() {
      filtersEl.innerHTML = FILTERS.map((f) =>
        '<button data-filter="' + f.key + '"' +
          ' style="background:' + (activeFilter === f.key ? '#0f172a' : '#f1f5f9') + ';' +
          'color:' + (activeFilter === f.key ? '#fff' : '#0f172a') + ';' +
          'padding:3px 9px;border:0;border-radius:999px;cursor:pointer;font-size:10px">' +
          escapeHTML(f.label) +
        '</button>'
      ).join('');
      filtersEl.querySelectorAll('[data-filter]').forEach((b) => {
        b.addEventListener('click', () => {
          activeFilter = b.dataset.filter;
          renderFilters();
          renderList();
        });
      });
    }

    function setStatus(text, color) {
      statusEl.textContent = text || '';
      statusEl.style.color = color || '#64748b';
    }

    function renderList() {
      const all = Array.from(tasksByID.values());
      const filtered = (activeFilter === 'all')
        ? all
        : all.filter((t) => (t.status === activeFilter) ||
                            (activeFilter === 'claimed' && t.status === 'inProgress'));
      filtered.sort((a, b) => (new Date(b.updatedAt || b.createdAt) - new Date(a.updatedAt || a.createdAt)));

      if (!sessionId) {
        listEl.innerHTML =
          '<div style="padding:20px 8px;text-align:center;color:#64748b">' +
            '<div style="font-size:11px;margin-bottom:10px">No active review session.</div>' +
            '<button data-act="start-session"' +
              ' style="background:#0f172a;color:#fff;border:0;border-radius:8px;padding:6px 14px;cursor:pointer;font-size:12px">' +
              'Start session' +
            '</button>' +
          '</div>';
        const btn = listEl.querySelector('[data-act="start-session"]');
        if (btn) btn.addEventListener('click', () => {
          if (typeof getSession === 'function') {
            Promise.resolve(getSession()).then((sid) => {
              if (sid) setSession(sid);
            });
          }
        });
        return;
      }

      if (!filtered.length) {
        listEl.innerHTML = '<div style="padding:20px 8px;text-align:center;color:#94a3b8;font-size:11px;font-style:italic">' +
          (activeFilter === 'all' ? 'No tasks yet · queue one from the canvas.' : 'No tasks in this filter.') +
        '</div>';
        return;
      }

      listEl.innerHTML = filtered.map((t) => {
        const cc = commentCount(t);
        const title = t.title || '(untitled)';
        return '<a href="/reviews/' + encodeURIComponent(t.sessionId) + '?task=' + encodeURIComponent(t.id) + '" target="_blank" rel="noopener"' +
          ' style="display:block;text-decoration:none;color:inherit;padding:8px 10px;margin-bottom:6px;' +
          'background:#fff;border:1px solid #e2e8f0;border-radius:8px">' +
          '<div style="display:flex;align-items:center;gap:6px;margin-bottom:4px">' +
            pill(t.status) +
            (cc ? '<span style="font-size:10px;color:#64748b" title="' + cc + ' comment(s)">💬 ' + cc + '</span>' : '') +
            '<span style="margin-left:auto;font-size:10px;color:#94a3b8">' + escapeHTML(timeAgo(t.updatedAt || t.createdAt)) + '</span>' +
          '</div>' +
          '<div style="font-size:12px;font-weight:500;line-height:1.35;overflow:hidden;text-overflow:ellipsis;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical">' +
            escapeHTML(title) +
          '</div>' +
          (t.assignee ? '<div style="font-size:10px;color:#64748b;margin-top:3px">@' + escapeHTML(t.assignee) + '</div>' : '') +
        '</a>';
      }).join('');
    }

    function applyTask(task) {
      if (!task || !task.id) return;
      tasksByID.set(task.id, task);
      renderList();
    }

    function applySnapshot(tasks) {
      tasksByID = new Map();
      (tasks || []).forEach((t) => { if (t && t.id) tasksByID.set(t.id, t); });
      renderList();
    }

    function setSession(sid) {
      sessionId = sid || null;
      tasksByID.clear();
      renderList();
      if (!stream) {
        stream = window.ReviewTasksStream && window.ReviewTasksStream.subscribe({
          sessionId: sessionId,
          onSnapshot:   (tasks) => applySnapshot(tasks),
          onTaskUpdate: (task)  => applyTask(task),
          onStatus:     (text, isError) => setStatus(text, isError ? '#991b1b' : undefined),
          onError:      () => {},
        });
      } else {
        stream.setSession(sessionId);
      }
    }

    toggleEl.addEventListener('change', () => {
      if (onSelectToggle) onSelectToggle(toggleEl.checked);
    });

    renderFilters();
    setSession(null);

    return {
      unmount() {
        unmounted = true;
        if (stream) { stream.close(); stream = null; }
        host.innerHTML = '';
      },
      setSession,
      setSelectToggle(checked) { toggleEl.checked = !!checked; },
      onSelectToggleChange(fn) { onSelectToggle = fn; },
      hideSelectToggle() {
        const lbl = toggleEl && toggleEl.parentElement;
        if (lbl) lbl.style.display = 'none';
      },
    };
  }

  window.SimActivity = { mount };
})();
