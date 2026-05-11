// review-code-changes.js — renders per-task source-file modifications.
// Each row shows path:lines + summary + an "open in VSCode" link +
// an expandable inline diff. Uses textContent everywhere — no innerHTML
// on agent-supplied strings — so a malicious diff cannot inject HTML.
(function () {
  'use strict';

  function renderInto(parent, codeChanges) {
    parent.replaceChildren();
    if (!codeChanges || !codeChanges.length) return;

    const header = document.createElement('div');
    header.style.cssText = 'margin-top:8px;font-size:11px;color:#475569;font-weight:600;text-transform:uppercase;letter-spacing:0.3px';
    header.textContent = 'Code changes (' + codeChanges.length + ')';
    parent.appendChild(header);

    for (const change of codeChanges) {
      parent.appendChild(renderRow(change));
    }

    const firstCommit = codeChanges.find((c) => c.commitSha);
    if (firstCommit) {
      const footer = document.createElement('div');
      footer.style.cssText = 'margin-top:4px;font-size:10px;color:#94a3b8;font-family:ui-monospace,SFMono-Regular,Menlo,monospace';
      const sha = footer.appendChild(document.createElement('span'));
      sha.textContent = 'commit ' + firstCommit.commitSha.slice(0, 8);
      if (firstCommit.branch) {
        const branch = footer.appendChild(document.createElement('span'));
        branch.textContent = '  ·  branch ' + firstCommit.branch;
      }
      parent.appendChild(footer);
    }
  }

  function renderRow(change) {
    const row = document.createElement('div');
    row.style.cssText = 'margin:4px 0;padding:6px 8px;background:#f8fafc;border:1px solid #e2e8f0;border-radius:6px;font-size:11px';

    const head = document.createElement('div');
    head.style.cssText = 'display:flex;gap:6px;align-items:center';

    const toggle = document.createElement('button');
    toggle.type = 'button';
    toggle.textContent = '▸';
    toggle.style.cssText = 'background:none;border:0;cursor:pointer;font-size:11px;color:#64748b;padding:0;width:14px';
    head.appendChild(toggle);

    const pathSpan = document.createElement('span');
    pathSpan.style.cssText = 'font-family:ui-monospace,SFMono-Regular,Menlo,monospace;color:#0f172a;flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap';
    pathSpan.textContent = formatPath(change);
    pathSpan.title = change.path;
    head.appendChild(pathSpan);

    if (change.summary) {
      const summary = document.createElement('span');
      summary.style.cssText = 'color:#475569';
      summary.textContent = change.summary;
      head.appendChild(summary);
    }

    const vscode = makeVSCodeLink(change);
    if (vscode) head.appendChild(vscode);

    if (change.diffText) {
      const diffBtn = document.createElement('button');
      diffBtn.type = 'button';
      diffBtn.textContent = 'view diff';
      diffBtn.style.cssText = 'background:none;border:0;color:#2563eb;cursor:pointer;font-size:11px;text-decoration:underline;padding:0';
      head.appendChild(diffBtn);

      const diff = document.createElement('pre');
      diff.style.cssText = 'display:none;margin:6px 0 0 14px;padding:6px 8px;background:#0f172a;color:#e2e8f0;border-radius:4px;font-size:10.5px;line-height:1.4;overflow:auto;max-height:300px;white-space:pre-wrap;word-break:break-all';
      diff.textContent = change.diffText;

      const toggleDiff = () => {
        const open = diff.style.display === 'none';
        diff.style.display = open ? 'block' : 'none';
        toggle.textContent = open ? '▾' : '▸';
      };
      toggle.addEventListener('click', toggleDiff);
      diffBtn.addEventListener('click', toggleDiff);

      row.appendChild(head);
      row.appendChild(diff);
    } else {
      row.appendChild(head);
    }

    return row;
  }

  function formatPath(change) {
    if (change.startLine && change.endLine && change.startLine !== change.endLine) {
      return change.path + ':' + change.startLine + '-' + change.endLine;
    }
    if (change.startLine) return change.path + ':' + change.startLine;
    return change.path;
  }

  function makeVSCodeLink(change) {
    if (!change.path) return null;
    const a = document.createElement('a');
    a.href = 'vscode://file/' + change.path + (change.startLine ? ':' + change.startLine : '');
    a.textContent = 'open in VSCode';
    a.style.cssText = 'color:#2563eb;font-size:11px;text-decoration:underline';
    a.target = '_blank';
    a.rel = 'noopener';
    return a;
  }

  window.ReviewCodeChanges = { renderInto };
})();
