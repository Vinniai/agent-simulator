// review-compare.js — side-by-side recording compare for /reviews/:sid.
// Mounts on the #compare-modal element wired in review.html. Pulls the
// recording list off the current session and feeds two <video> elements
// from the artifact endpoint; a shared <input type="range"> drives both
// currentTime values in lockstep. Pre-roll alignment defaults to t=0
// when both recordings share fromSnapshotId.
(function () {
  'use strict';

  let modal, leftSel, rightSel, leftVid, rightVid, scrub, playBtn, timeEl, driftEl;
  let session = null;
  let playing = false;
  let scrubMax = 1000;

  function init() {
    modal     = document.getElementById('compare-modal');
    if (!modal) return;
    leftSel   = modal.querySelector('[data-role="compare-left"]');
    rightSel  = modal.querySelector('[data-role="compare-right"]');
    leftVid   = modal.querySelector('[data-role="compare-left-video"]');
    rightVid  = modal.querySelector('[data-role="compare-right-video"]');
    scrub     = document.getElementById('compare-scrub');
    playBtn   = document.getElementById('compare-play');
    timeEl    = document.getElementById('compare-time');
    driftEl   = document.getElementById('compare-drift');

    document.getElementById('compare-close').onclick = close;
    document.getElementById('open-compare').onclick = open;

    leftSel.onchange  = () => setSrc(leftVid,  leftSel.value);
    rightSel.onchange = () => setSrc(rightVid, rightSel.value);

    scrub.oninput = () => {
      const t = (scrub.value / scrubMax) * maxDuration();
      seek(leftVid, t);
      seek(rightVid, t);
      updateReadout();
    };

    playBtn.onclick = () => {
      playing = !playing;
      playBtn.textContent = playing ? 'Pause' : 'Play';
      if (playing) {
        leftVid.play().catch(() => {});
        rightVid.play().catch(() => {});
      } else {
        leftVid.pause();
        rightVid.pause();
      }
    };

    [leftVid, rightVid].forEach((v) => {
      v.addEventListener('timeupdate', () => {
        const t = leftVid.currentTime;
        const m = maxDuration();
        if (m > 0) scrub.value = String(Math.round((t / m) * scrubMax));
        updateReadout();
      });
      v.addEventListener('ended', () => {
        if (leftVid.ended && rightVid.ended) {
          playing = false;
          playBtn.textContent = 'Play';
        }
      });
    });
  }

  function open() {
    if (!modal) init();
    session = window.ReviewCompare && window.ReviewCompare.session;
    populate();
    modal.style.display = 'flex';
  }

  function close() {
    if (!modal) return;
    leftVid.pause();
    rightVid.pause();
    playing = false;
    playBtn.textContent = 'Play';
    modal.style.display = 'none';
  }

  function populate() {
    const recs = (session && session.recordings) || [];
    const opts = recs.map((r, i) => {
      const label = recordingLabel(r, i);
      return '<option value="' + escapeAttr(r.filename) + '">' + escapeHTML(label) + '</option>';
    }).join('');
    const placeholder = '<option value="">Pick a recording…</option>';
    leftSel.innerHTML  = placeholder + opts;
    rightSel.innerHTML = placeholder + opts;
    leftSel.value = '';
    rightSel.value = '';
    leftVid.removeAttribute('src');
    rightVid.removeAttribute('src');
    scrub.value = '0';
    updateReadout();
  }

  function recordingLabel(r, i) {
    const stamp = r.createdAt ? new Date(r.createdAt).toLocaleString() : '#' + (i + 1);
    const d = typeof r.durationSeconds === 'number' ? ` · ${r.durationSeconds.toFixed(1)}s` : '';
    return `${stamp}${d}`;
  }

  function setSrc(vid, relativePath) {
    if (!relativePath || !session) { vid.removeAttribute('src'); return; }
    const url = `/reviews/${encodeURIComponent(session.id)}/artifact?path=${encodeURIComponent(relativePath)}`;
    vid.src = url;
    vid.currentTime = 0;
    if (playing) vid.play().catch(() => {});
  }

  function seek(vid, t) {
    if (!vid.duration || isNaN(vid.duration)) return;
    vid.currentTime = Math.max(0, Math.min(t, vid.duration));
  }

  function maxDuration() {
    return Math.max(leftVid.duration || 0, rightVid.duration || 0);
  }

  function updateReadout() {
    const t = leftVid.currentTime || 0;
    const m = maxDuration();
    timeEl.textContent = `${t.toFixed(2)} / ${m.toFixed(2)}s`;
    const drift = Math.abs((leftVid.currentTime || 0) - (rightVid.currentTime || 0));
    driftEl.textContent = drift > 0.05 ? `drift ${drift.toFixed(2)}s` : 'in sync';
  }

  function escapeHTML(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    })[c]);
  }
  function escapeAttr(s) { return escapeHTML(s); }

  window.ReviewCompare = {
    session: null,
    setSession(s) { this.session = s; },
    open,
    close,
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init, { once: true });
  } else {
    init();
  }
})();
