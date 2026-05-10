(function () {
  'use strict';

  function installReviewWidget(opts) {
    if (document.getElementById('baguette-review-widget')) return;
    const getUdid = opts && opts.getUdid || (() => null);
    const box = document.createElement('div');
    box.id = 'baguette-review-widget';
    box.style.cssText = 'position:fixed;right:14px;bottom:14px;z-index:50;background:#fff;border:1px solid #d8dee8;border-radius:8px;box-shadow:0 10px 30px rgba(15,23,42,.18);padding:10px;width:220px;font:12px -apple-system,BlinkMacSystemFont,SF Pro Text,sans-serif;color:#1f2937';
    box.innerHTML = `
      <div style="font-weight:650;margin-bottom:8px">Review Mode</div>
      <button data-act="new" style="width:100%;margin-bottom:6px">New session</button>
      <button data-act="capture" style="width:100%;margin-bottom:6px">Capture state</button>
      <button data-act="open" style="width:100%">Open map</button>
      <div data-role="status" style="margin-top:8px;color:#64748b;min-height:16px"></div>
    `;
    document.body.appendChild(box);
    let sessionId = localStorage.getItem('baguette.review.session') || '';
    const status = box.querySelector('[data-role="status"]');
    const setStatus = (s) => { status.textContent = s || ''; };
    async function createSession() {
      const name = prompt('Review name', 'Simulator review') || 'Simulator review';
      const res = await fetch('/reviews', {
        method:'POST', headers:{'content-type':'application/json'},
        body:JSON.stringify({ name })
      });
      const session = await res.json();
      sessionId = session.id;
      localStorage.setItem('baguette.review.session', sessionId);
      setStatus('Session ready');
      return sessionId;
    }
    box.querySelector('[data-act="new"]').onclick = createSession;
    async function ensureSession() {
      return sessionId || await createSession();
    };
    box.querySelector('[data-act="capture"]').onclick = async () => {
      const udid = getUdid();
      if (!udid) { setStatus('No simulator selected'); return; }
      const id = await ensureSession();
      setStatus('Capturing...');
      try {
        const res = await fetch(`/reviews/${encodeURIComponent(id)}/capture`, {
          method:'POST', headers:{'content-type':'application/json'},
          body:JSON.stringify({ udid, actionType:'manual' })
        });
        if (!res.ok) throw new Error(await res.text());
        setStatus('Captured');
      } catch (e) {
        console.warn('[review] capture failed', e);
        setStatus('Capture failed');
      }
    };
    box.querySelector('[data-act="open"]').onclick = () => {
      window.open(sessionId ? `/reviews/${encodeURIComponent(sessionId)}` : '/reviews', '_blank');
    };
  }

  window.BaguetteReviewClient = { install: installReviewWidget };
})();
