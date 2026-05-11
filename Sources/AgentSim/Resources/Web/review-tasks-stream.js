// review-tasks-stream.js — pure WS subscriber for /review-tasks/stream
// with auto-reconnect. No DOM, no rendering. Consumers (sim-activity
// dock on /simulators/:UDID, review.js on /reviews/:sid) bring their
// own rendering and feed updates back via onSnapshot / onTaskUpdate.
//
// Public API:
//   ReviewTasksStream.subscribe({ sessionId, onSnapshot, onTaskUpdate, onStatus, onError })
//     → { close, setSession(newId) }
//
//   - sessionId:  string  — pass falsy to start in idle/disconnected state
//   - onSnapshot: (tasks: ReviewTask[]) => void
//   - onTaskUpdate: (task: ReviewTask) => void
//   - onStatus: (msg: string | '', isError?: boolean) => void
//   - onError: (err: Error) => void

(function () {
  'use strict';

  function buildURL(sessionId) {
    const loc = window.location;
    const proto = loc.protocol === 'https:' ? 'wss:' : 'ws:';
    return proto + '//' + loc.host + '/review-tasks/stream?sessionId=' + encodeURIComponent(sessionId);
  }

  function subscribe(opts) {
    const onSnapshot   = opts.onSnapshot   || (() => {});
    const onTaskUpdate = opts.onTaskUpdate || (() => {});
    const onStatus     = opts.onStatus     || (() => {});
    const onError      = opts.onError      || (() => {});

    let sessionId  = opts.sessionId || '';
    let ws = null;
    let reconnectTimer = null;
    let closed = false;

    function handleMessage(text) {
      let env;
      try { env = JSON.parse(text); } catch { return; }
      if (!env || typeof env !== 'object') return;
      if (env.type === 'task_stream_started') return;
      if (env.type === 'task_stream_error') {
        onStatus(env.error || 'stream error', true);
        return;
      }
      if (env.type === 'task_update') {
        if (env.task) onTaskUpdate(env.task);
        return;
      }
      if (Array.isArray(env.tasks)) {
        onSnapshot(env.tasks);
        return;
      }
    }

    function connect() {
      if (closed || !sessionId) return;
      try {
        ws = new WebSocket(buildURL(sessionId));
      } catch (e) {
        onStatus('connect failed · retrying', true);
        onError(e);
        scheduleReconnect();
        return;
      }
      onStatus('connecting…');
      ws.addEventListener('open',    () => onStatus(''));
      ws.addEventListener('message', (e) => handleMessage(e.data));
      ws.addEventListener('close',   () => {
        if (closed) return;
        onStatus('disconnected · retrying');
        scheduleReconnect();
      });
      ws.addEventListener('error', () => {
        onStatus('error · retrying', true);
      });
    }

    function scheduleReconnect() {
      if (closed) return;
      clearTimeout(reconnectTimer);
      reconnectTimer = setTimeout(connect, 2500);
    }

    function tearDown() {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
      if (ws) { try { ws.close(); } catch (_) { /* ignore */ } ws = null; }
    }

    function setSession(nextId) {
      const next = nextId || '';
      if (next === sessionId) return;
      sessionId = next;
      tearDown();
      if (!sessionId) {
        onStatus('');
        onSnapshot([]);
        return;
      }
      connect();
    }

    if (sessionId) connect();
    else onStatus('');

    return {
      close() { closed = true; tearDown(); },
      setSession,
    };
  }

  window.ReviewTasksStream = { subscribe };
})();
