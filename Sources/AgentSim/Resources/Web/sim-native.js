// sim-native.js — focus mode at /simulators/<udid>.
//
// Activates only when the page is loaded directly with a UDID in the
// path. Renders a macOS-Simulator-style window chrome (traffic
// lights, centered device title, top-right Home / Screenshot / Lock
// toolbar) wrapping a focused live-stream surface. Reuses the same
// modules as sim-stream.js — DeviceFrame, FrameDecoder, StreamSession,
// SimInput, MouseGestureSource, PinchOverlay — without the sidebar.
//
// Sets `window.__agentSimNativeMode = true` *synchronously* so
// sim-list.js (loaded later) can early-return and not paint the list
// underneath us.
(function () {
  'use strict';

  // --- Activation gate ---------------------------------------------
  // Match `/simulators/<udid>` (desktop deep-link) or `/m/<udid>`
  // (mobile entry point); reject the bare `/simulators` and `/m`
  // list/dashboard paths. UDIDs never contain `/`, so the second
  // segment being non-empty is the discriminator.
  function deepLinkUdid() {
    const parts = location.pathname.split('/').filter(Boolean);
    if (parts.length !== 2) return null;
    if (parts[0] !== 'simulators' && parts[0] !== 'm') return null;
    const u = decodeURIComponent(parts[1]);
    if (!u) return null;
    return u;
  }

  const udid = deepLinkUdid();
  if (!udid) return; // not deep-link mode; let sim-list run.
  window.__agentSimNativeMode = true;

  // `/m/<udid>` is the on-the-move mobile screen: same focus chrome,
  // but stripped to the live stream + AX element picker + a
  // chat-to-queue composer (no toolbar actions / format / logs). The
  // first path segment is the discriminator (`m` vs `simulators`).
  const isMobile = location.pathname.split('/').filter(Boolean)[0] === 'm';

  // --- State -------------------------------------------------------
  let session = null;
  let frame = null;
  let surface = null;
  let simInput = null;
  let mouseSource = null;
  let touchSource = null;   // real multi-touch on phones/tablets
  let pinchOverlay = null;
  let keyboardCapture = null;
  let logPanel = null;
  let axInspector = null;
  let lastAxNode = null;    // last element picked while in mobile select-mode
  let activityTimer = null;     // fallback poll handle (only while WS down)
  let activityStream = null;    // `WS /notes/stream` socket (primary)
  let activityReconnect = null; // backoff timer for socket reconnect
  let activityClosed = false;   // page unloading — stop reconnecting
  let lastPaintedSize = { w: 0, h: 0 };
  let layout = null;
  let deviceName = '';

  // CW rotation cycle. Two flavours — iPhone UIKit refuses
  // `portrait-upside-down` for apps that don't opt in (which is
  // basically every Apple-shipped iPhone app), so the cycle skips
  // it on phones to keep every click visibly productive. iPads
  // and other tablet-class devices honour all four. The Domain /
  // CLI / HTTP layers still accept `portrait-upside-down`
  // unconditionally — this trim is UI ergonomics only.
  // Starting index is `0` (portrait); we don't probe the guest
  // because the GSEvent path is write-only.
  // Every wire-name `DeviceOrientation` accepts is reachable from
  // the rotate-button cycle, on phones and tablets alike. The
  // order matches a true 90°-clockwise visual rotation per click:
  //   portrait              (CSS rotate(0))
  //   landscape-left        (CSS rotate(90deg)   — home on left of visual)
  //   portrait-upside-down  (CSS rotate(180deg))
  //   landscape-right       (CSS rotate(-90deg)  — home on right of visual)
  // Names refer to *home-button position* on the rotated bezel
  // (Apple's UIDeviceOrientation convention), not direction of
  // rotation — which is why `landscape-left` comes first in a
  // clockwise cycle. iPhone UIKit silently ignores
  // `portrait-upside-down` for apps that don't declare the
  // interface orientation; the cycle still exposes it so apps
  // that *do* honour it are reachable.
  const ORIENTATION_CYCLE = [
    'portrait', 'landscape-left', 'portrait-upside-down', 'landscape-right',
  ];
  let orientationIndex = 0;
  let currentOrientation = 'portrait';

  // Debug knobs for landscape-right edge-gesture exploration —
  // iOS in raw=3 doesn't fire the home recognizer on any of the
  // recipes that work for landscape-left / upside-down, so we
  // expose runtime overrides so the next drag uses a different
  // (edge, coord) combination without a rebuild.
  //   window.__edgeOverride('top'|'right'|'bottom'|'left'|null)
  //   window.__mirrorX(true|false)         — flip portrait_x via {x: y, y: x}
  //   window.__lrConfig()                  — print current state
  //   window.__lrReset()                   — restore defaults
  let lrEdgeOverride = null;     // null → use the default mapping
  let lrMirrorX      = false;    // false → strict CSS-rotation inverse
  if (typeof window !== 'undefined') {
    window.__edgeOverride = (e) => { lrEdgeOverride = e || null; console.log('[lr] edge override =', lrEdgeOverride); };
    window.__mirrorX      = (b) => { lrMirrorX = !!b;             console.log('[lr] mirror-X =', lrMirrorX); };
    window.__lrReset      = ()  => { lrEdgeOverride = null; lrMirrorX = false; console.log('[lr] reset'); };
    window.__lrConfig     = ()  => { console.log('[lr]', { edgeOverride: lrEdgeOverride, mirrorX: lrMirrorX }); };
  }
  // Absolute rotation degrees, monotonically increasing — each
  // rotate-button click adds 90. Applied inline so CSS transitions
  // interpolate the *short* way (always +90° forward) instead of
  // the long way around when the wire-name's canonical angle
  // would have decreased (e.g. 180° → -90° = -270° animation
  // would be visibly weird). Modulo 360 just keeps the number
  // tidy; the transition driver doesn't care about absolute size.
  let rotationDegrees = 0;

  function orientationCycle() {
    return ORIENTATION_CYCLE;
  }

  // Apply orientation visually: set the inline `transform` on the
  // device-frame wrapper, plus a `data-orientation` attribute on
  // the container so non-rotation CSS (max-height caps in
  // landscape) and the input/overlay coord transforms can read
  // `currentOrientation`.
  function applyOrientation(value) {
    const previous = currentOrientation;
    currentOrientation = value;
    const root = document.getElementById('nativeDeviceFrame');
    if (root) {
      if (value === 'portrait') root.removeAttribute('data-orientation');
      else                      root.setAttribute('data-orientation', value);
      // Advance the rotation by one cycle step (90° CW) when we
      // move forward in the cycle. If the caller asked for the
      // same orientation we already display (e.g. session restart
      // after format swap), keep the existing degrees so the
      // bezel doesn't re-animate.
      if (value !== previous) {
        rotationDegrees += 90;
      }
      const wrapper = root.querySelector(':scope > div');
      if (wrapper) wrapper.style.transform = 'rotate(' + rotationDegrees + 'deg)';
    }
  }

  // Map a normalized coord [0, 1]² from the rotated visual frame
  // back to the device's portrait coord system. Used by the input
  // transport so taps/swipes/touches land on the iOS element the
  // user clicked on, even though iOS expects portrait coords.
  // Direction must mirror the CSS transforms in sim-native.html —
  // landscape-right is rotate(-90deg) (CCW) on the wrapper, so the
  // visual→portrait inverse rotates CW.
  function visualToPortraitNorm(x, y) {
    switch (currentOrientation) {
      case 'landscape-right':       return { x: 1 - y,     y: x         };
      case 'portrait-upside-down':  return { x: 1 - x,     y: 1 - y     };
      case 'landscape-left':        return { x: y,         y: 1 - x     };
      default:                      return { x,            y            };
    }
  }

  // Map a screen-edge name from the user's visual frame to the
  // device's portrait coord frame. When the device is rotated, the
  // user's visual bottom corresponds to a *different* physical
  // edge in portrait coords (the frame the digitizer dispatch
  // patches `IndigoHIDEdge` against). Without this remap, a swipe
  // up from the visual bottom in landscape lands as portrait coords
  // near the left/right edge but is still flagged `bottom` — iOS's
  // gesture recognizer requires the flag to match the touch's
  // physical edge, so the home gesture never fires.
  //
  //   portrait                : visual bottom → physical bottom
  //   landscape-right         : visual bottom → physical left
  //   portrait-upside-down    : visual bottom → physical top
  //   landscape-left          : visual bottom → physical right
  //
  // Same rotation applies to all four edge names — derived from
  // the same CSS rotate transforms the bezel uses.
  function visualToPortraitEdge(edge) {
    if (!edge) return edge;
    // Empirical mapping (verified against iOS 26.4 home-indicator
    // recognizer in our headless setup):
    //   portrait                : bottom → bottom
    //   landscape-left  (raw=4) : bottom → right   (rotateCW; verified)
    //   landscape-right (raw=3) : bottom → left    (rotateCCW; recognizer not wired — known limitation)
    //   portrait-upside-down    : bottom → right   (matches raw=4 path; verified)
    //
    // iOS rotates the home-indicator recognizer hot zone with
    // orientation for raw=4 and raw=2 — both end up at
    // portrait-right + edge=right. raw=3 *should* mirror to
    // portrait-left + edge=left by the same logic, but iOS
    // doesn't fire the recognizer there in our headless setup
    // (the well-documented landscape-right gap). Sending edge=left
    // keeps the wire envelope physically self-consistent (touch
    // coords land on portrait-left, edge flag agrees) so the
    // gesture isn't mis-routed to a different system region.
    // Empirical mapping (verified):
    //   portrait              : bottom → bottom  (✅ home fires)
    //   landscape-left  (raw=4): bottom → right  (✅ home fires)
    //   portrait-upside-down  : bottom → right  (✅ home fires)
    //   landscape-right (raw=3): bottom → top    (✅ home fires)
    switch (currentOrientation) {
      case 'landscape-left':       return edge === 'bottom' ? 'right' : edge;
      case 'portrait-upside-down': return edge === 'bottom' ? 'right' : edge;
      case 'landscape-right':      return edge === 'bottom' ? 'top' : edge;
      default:                     return edge;
    }
  }

  // Map a pixel coord from the rotated visual bbox back to the
  // unrotated DOM-local frame (the screenArea's own pre-rotation
  // pixel grid). Used when placing pinch-overlay dots — their CSS
  // left/top is in unrotated local pixels, so we have to undo the
  // wrapper's rotation before the dot lines up under the cursor.
  function visualToUnrotatedLocalPx(vx, vy, w, h) {
    switch (currentOrientation) {
      case 'landscape-right':       return { x: h - vy,    y: vx        };
      case 'portrait-upside-down':  return { x: w - vx,    y: h - vy    };
      case 'landscape-left':        return { x: vy,        y: w - vx    };
      default:                      return { x: vx,        y: vy        };
    }
  }

  // --- Bootstrap ---------------------------------------------------
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot, { once: true });
  } else {
    boot();
  }

  async function boot() {
    // Reset whatever sim.html landed with. Body gets `margin:0;
    // overflow:hidden;` so the focus-mode UI fills the viewport,
    // but the *background* is left to the focus-mode stylesheet —
    // it tracks the user's prefers-color-scheme via CSS variables,
    // so hardcoding a colour here would defeat the theme switch.
    document.body.innerHTML = '';
    if (window.AgentSimReviewClient) {
      window.AgentSimReviewClient.install({
        getUdid: () => udid,
        getInspector: () => axInspector,
      });
    }
    document.body.style.cssText = 'margin:0;padding:0;overflow:hidden';
    // Match <body> background to the active focus-mode page bg so
    // the page never flashes white during theme transitions or
    // before the template paints.
    document.body.style.background = 'var(--nv-page-bg, #1a1a1f)';

    // 1. Load template + inline styles from sim-native.html.
    const html = await fetchTemplate();
    if (!html) {
      document.body.innerHTML =
          '<pre style="color:#f87171;padding:24px;font-family:ui-monospace">sim-native.html not found</pre>';
      return;
    }
    document.body.insertAdjacentHTML('beforeend', html);

    // 2. Resolve device name + iOS runtime from the list endpoint.
    //    chrome.json gives us the bezel; /simulators.json gives us
    //    the human-readable identity that sits above it.
    const meta = await fetchDeviceMeta(udid);
    deviceName = meta.name;
    const nameEl = document.getElementById('nativeDeviceName');
    const osEl = document.getElementById('nativeDeviceOS');
    if (nameEl) nameEl.textContent = meta.name;
    if (osEl)   osEl.textContent   = meta.runtime;
    document.title = `${meta.name} — Agent Sim`;

    // 3. Layout drives bezel + screen rect + corner radius. Same
    //    endpoint sim-stream.js uses.
    layout = await fetch(`/simulators/${encodeURIComponent(udid)}/chrome.json`)
        .then((r) => (r.ok ? r.json() : null))
        .catch(() => null);

    // 4. Mount frame. Actionable mode is opt-in (toolbar toggle,
    //    persisted to localStorage). When on, `bezel.png?buttons=
    //    false` is fetched and BezelButtons overlays each hardware
    //    button with hover/click animations that fire SimInput.
    frame = new window.DeviceFrame({
      udid, layout,
      actionable: actionableEnabled(),
      onPress: (name, duration) => simInput && simInput.button(name, duration),
    });
    surface = frame.mount(document.getElementById('nativeDeviceFrame'));

    // 5. Open stream + wire input.
    startSession(pickFormat());

    wireKeyboard();
    wireActions();
    wireUnload();
    applyStoredTheme();
    reflectActionable();

    // Mobile-mode chrome: tag the root so the stylesheet hides the
    // desktop toolbar clutter (format picker, actionable, rotate,
    // logs/home/screenshot/app-switcher, sidebar/theme toggles),
    // then mount the bottom dock — a collapsible activity drawer
    // (what's queued / picked up) above the chat-to-queue composer.
    if (isMobile) {
      const root = document.getElementById('simNativeView');
      if (root) root.setAttribute('data-mobile', 'true');
      injectBottomDock();
      startActivityPolling();
    }

    // Reset iOS to portrait on page boot. Without this, a page
    // reload would leave our JS state at `currentOrientation =
    // 'portrait'` (rotation degrees 0) while iOS still holds
    // whatever orientation it was set to in a previous session
    // — the bezel renders un-rotated but the iOS framebuffer
    // shows UI from the stale orientation, which looks upside
    // down to the user.
    fetch('/simulators/' + encodeURIComponent(udid) + '/orientation?value=portrait',
        { method: 'POST' }).catch(() => { /* best-effort */ });
  }

  // Actionable-bezel toggle. Off by default — the bezel renders
  // as today's flat composite. On, the device-frame swaps to
  // `bezel.png?buttons=false` and BezelButtons overlays each
  // hardware button with hover/click animations.
  const ACTIONABLE_KEY = 'agentsim.actionableBezel';
  function actionableEnabled() {
    return localStorage.getItem(ACTIONABLE_KEY) === '1'
        || localStorage.getItem('baguette.actionableBezel') === '1';
  }
  function setActionable(on) {
    if (on) localStorage.setItem(ACTIONABLE_KEY, '1');
    else    localStorage.removeItem(ACTIONABLE_KEY);
  }

  // Theme toggle. Three logical states — "auto" (no manual pin,
  // follow OS via prefers-color-scheme), "light", "dark". The pill
  // in the bottom-right corner cycles light ↔ dark; we don't
  // expose "auto" from the click cycle because the icon set has
  // only two states. The user can reset to auto by deleting the
  // localStorage key in DevTools if needed.
  const THEME_KEY = 'agentsim.simTheme';

  function applyStoredTheme() {
    const stored = localStorage.getItem(THEME_KEY)
      ?? localStorage.getItem('baguette.simTheme');
    if (stored === 'light' || stored === 'dark') {
      setTheme(stored);
    }
  }

  function currentTheme() {
    const root = document.getElementById('simNativeView');
    const pinned = root && root.getAttribute('data-theme');
    if (pinned === 'light' || pinned === 'dark') return pinned;
    return window.matchMedia('(prefers-color-scheme: light)').matches
        ? 'light' : 'dark';
  }

  function setTheme(theme) {
    const root = document.getElementById('simNativeView');
    if (!root) return;
    if (theme === 'light' || theme === 'dark') {
      root.setAttribute('data-theme', theme);
      localStorage.setItem(THEME_KEY, theme);
    } else {
      root.removeAttribute('data-theme');
      localStorage.removeItem(THEME_KEY);
    }
  }

  // Open (or reopen) a StreamSession on the existing surface for a
  // given wire format. Tearing down + restarting is the cheapest way
  // to swap formats — the WS protocol is per-connection and the
  // server's makeStream(...) is keyed at session open.
  function startSession(format) {
    if (session) { try { session.stop(); } catch (_) {} session = null; }
    // Same text-frame router as sim-stream.js: hand JSON envelopes
    // to the inspector first; anything it doesn't claim falls
    // through to the decoder's error logger.
    const onStreamText = (env) => {
      if (axInspector && axInspector.handleEnvelope(env)) return true;
      return false;
    };
    session = new window.StreamSession({
      udid, format, version: 'v2',
      canvas: surface.canvas,
      onSize: (w, h) => { lastPaintedSize = { w, h }; },
      onFps:  (fps) => {
        const el = document.getElementById('nativeStatus');
        if (el) el.textContent = fps + ' fps';
      },
      onLog: (msg) => console.log('[native]', msg),
      onText: onStreamText,
    });
    session.start();
    reflectFormat(format);
    wireInput(udid, frame.screenSize());
    mountAxInspector();
  }

  // Lazy-mounts the AXInspector once a surface + session are ready.
  // Re-runs on `remountFrame()` because the screen DOM and the
  // session both change underneath it.
  //
  // Focus-mode UX:
  //   - The inspector has no inline UI host. Enable/disable is
  //     driven by the `nativeAxToggle` toolbar button.
  //   - Selection details surface in the `nativeAxHost` floating
  //     panel, which is hidden until the user clicks an element.
  function mountAxInspector() {
    if (axInspector) {
      try { axInspector.detach(); } catch (_) { /* ignore */ }
      axInspector = null;
    }
    if (!window.AXInspector || !surface) return;
    const panel = document.getElementById('nativeAxHost');
    axInspector = new window.AXInspector({
      // No `host` — toolbar drives enable/disable, panel surfaces selection.
      screenArea: surface.screenArea,
      send: (payload) => session && session.send(payload),
      getDeviceSize: () => frame.screenSize(),
      onSelect: (node) => {
        lastAxNode = node;
        renderAxPanel(panel, node);
        updateComposerContext();
      },
      onEnableChange: (enabled) => {
        const btn = document.getElementById('nativeAxToggle');
        if (btn) btn.classList.toggle('active', enabled);
        if (!enabled && panel) {
          panel.removeAttribute('data-open');
          panel.innerHTML = '';
        }
      },
    });
    // On the on-the-move screen the picker IS the primary interaction
    // (tap = select an element to attach a note to), so it's on by
    // default — the AX toggle in the bar still flips back to drive-mode.
    if (isMobile) {
      try { axInspector.enable(); } catch (_) { /* ignore */ }
    }
  }

  function reflectFormat(format) {
    document.querySelectorAll('#nativeFormatPicker .fmt-btn').forEach((b) => {
      b.classList.toggle('active', b.dataset.v === format);
    });
  }

  // --- Helpers -----------------------------------------------------
  let _templatePromise = null;
  function fetchTemplate() {
    if (_templatePromise) return _templatePromise;
    _templatePromise = fetch('/sim-native.html')
        .then((r) => (r.ok ? r.text() : ''))
        .then((html) => {
          if (!html) return '';
          const doc = new DOMParser().parseFromString(html, 'text/html');
          // Carry the inline <style> blocks (they live in <body>) plus
          // the #simNativeView root. The standalone-preview <script>
          // is ignored — boot() owns the wiring instead.
          const styles = Array.from(doc.body.querySelectorAll('style'))
              .map((s) => s.outerHTML).join('\n');
          const root = doc.getElementById('simNativeView');
          return styles + (root ? root.outerHTML : '');
        })
        .catch(() => '');
    return _templatePromise;
  }

  async function fetchDeviceMeta(targetUdid) {
    try {
      const r = await fetch('/simulators.json', { cache: 'no-store' });
      if (!r.ok) throw new Error(String(r.status));
      const json = await r.json();
      const all = (json.running || []).concat(json.available || []);
      const hit = all.find((d) => (d.id || d.udid) === targetUdid);
      if (hit) {
        return {
          name: hit.name || 'Simulator',
          runtime: hit.displayRuntime
              || formatRuntime(hit.runtime || hit.os || ''),
        };
      }
    } catch (_) { /* fall through */ }
    return { name: 'Simulator', runtime: '' };
  }

  function formatRuntime(raw) {
    return String(raw || '')
        .replace('com.apple.CoreSimulator.SimRuntime.', '')
        .replace(/^iOS-/, 'iOS ')
        .replace(/-/g, '.');
  }

  function pickFormat() {
    const stored = localStorage.getItem('asc.simFormat');
    if (stored === 'avcc' || stored === 'mjpeg') return stored;
    return window.FrameDecoder && window.FrameDecoder.isHardwareAvailable()
        ? 'avcc' : 'mjpeg';
  }

  function wireInput(targetUdid, screenSize) {
    // Detach any prior wiring — startSession() can be called multiple
    // times when the user swaps formats, and a fresh transport must
    // be bound to the new session. Without the detach the old
    // overlay handlers stack up and pinch dots leak.
    if (mouseSource) { try { mouseSource.detach(); } catch (_) {} mouseSource = null; }
    if (touchSource) { try { touchSource.detach(); } catch (_) {} touchSource = null; }
    if (pinchOverlay) { try { pinchOverlay.clear(); } catch (_) {} pinchOverlay = null; }

    const log = (msg) => console.log('[native]', msg);
    simInput = new window.SimInput({
      udid: targetUdid,
      log,
      // Shared translator from sim-input-bridge.js — wrapped here
      // so user gestures captured in the rotated visual frame are
      // remapped back to the device's portrait coord system
      // before the bridge converts them to wire envelopes.
      transport: makeOrientationTransport(session, log),
    });
    simInput.setScreenSize(screenSize.w, screenSize.h);
    pinchOverlay = makeOrientationPinchOverlay(surface.screenArea);
    // Restore the cached orientation across format-swap remounts,
    // so reopening the session doesn't snap the device back to
    // portrait while the simulator is still landscape.
    if (currentOrientation !== 'portrait') applyOrientation(currentOrientation);
    mouseSource = new window.MouseGestureSource({
      el: surface.screenArea,
      input: simInput,
      overlay: pinchOverlay,
      log,
      getOrientation: () => currentOrientation,
    });
    mouseSource.attach();
    // Real touch (phones/tablets). Orientation remap is handled at the
    // transport + overlay layer (both shared via simInput / pinchOverlay),
    // so the touch source needs no getOrientation of its own. preventDefault()
    // in its handlers stops the browser synthesising duplicate mouse events.
    touchSource = new window.TouchGestureSource({
      el: surface.screenArea,
      input: simInput,
      overlay: pinchOverlay,
      log,
    });
    touchSource.attach();
  }

  // Wrap SimInputBridge's transport with a normalized-coord
  // remapper. MouseGestureSource computes finger coords against
  // screenArea's bounding rect, which after CSS rotation is the
  // ROTATED bbox — so the normalized [0, 1] coords arriving here
  // are in the user's visual frame. We translate them to portrait
  // device-norm before the bridge multiplies by width/height
  // (still portrait pixel dims) to produce wire envelopes.
  function makeOrientationTransport(session, log) {
    const inner = window.SimInputBridge.makeTransport(session, log);
    return (payload) => inner(remapPayloadToPortrait(payload));
  }

  function remapPayloadToPortrait(payload) {
    if (currentOrientation === 'portrait' || !payload) return payload;
    switch (payload.kind) {
      case 'tap': {
        const p = visualToPortraitNorm(payload.x, payload.y);
        return { ...payload, x: p.x, y: p.y };
      }
      case 'swipe': {
        const a = visualToPortraitNorm(payload.x1, payload.y1);
        const b = visualToPortraitNorm(payload.x2, payload.y2);
        return { ...payload, x1: a.x, y1: a.y, x2: b.x, y2: b.y };
      }
      case 'touchDown':
      case 'touchMove':
      case 'touchUp': {
        const fingers = (payload.fingers || []).map((f) => visualToPortraitNorm(f.x, f.y));
        const edge = visualToPortraitEdge(payload.edge);
        return { ...payload, fingers, edge };
      }
      default:
        return payload;
    }
  }

  // Wrap PinchOverlay so dot positions are placed in the
  // unrotated DOM-local frame even when the user's cursor (and
  // therefore the (x, y) we receive) is in the rotated visual
  // frame. Without this, dots drift away from the cursor as soon
  // as the device is in landscape.
  function makeOrientationPinchOverlay(host) {
    const inner = new window.PinchOverlay(host);
    return {
      setFingers(points) {
        if (currentOrientation === 'portrait') return inner.setFingers(points);
        const r = host.getBoundingClientRect();
        const w = r.width, h = r.height;
        const remapped = points.map(({ x, y }) => visualToUnrotatedLocalPx(x, y, w, h));
        return inner.setFingers(remapped);
      },
      clear() { inner.clear(); },
    };
  }

  // Wire host-keyboard → simulator. Focus-gated: while the screen
  // area has focus, every supported keystroke is forwarded as a wire
  // `key` event (W3C `event.code` + modifier flags); when focus is
  // elsewhere (toolbar, header, etc.) the host browser keeps its
  // shortcuts. `mousedown` on the screen takes focus so the gate
  // opens automatically when the user starts interacting with iOS.
  function wireKeyboard() {
    const el = surface.screenArea;
    el.addEventListener('mousedown', () => el.focus());
    keyboardCapture = new window.KeyboardCapture({ target: el, simInput: () => simInput });
    keyboardCapture.start();
  }

  function wireActions() {
    window.__nativeHome = () => simInput && simInput.button('home');
    // App switcher — fires the new `app-switcher` virtual button
    // on the server side. The Swift `IndigoHIDInput` decomposes it
    // into two consecutive home `IndigoHIDMessageForButton` presses
    // ~150 ms apart, which is the recipe SpringBoard listens for
    // (works on Face ID iPhones with no physical home button). No
    // gesture coordinates involved, so device rotation is a non-
    // issue here.
    window.__nativeAppSwitcher = () => simInput && simInput.button('app-switcher');
    window.__nativeScreenshot = () => downloadSnapshot();
    window.__nativeClose = () => {
      // Shutting the window from inside a popup-style URL: try
      // window.close (only works for script-opened tabs) then fall
      // back to navigating to the list.
      try { window.close(); } catch (_) { /* ignore */ }
      if (!window.closed) location.href = '/simulators';
    };
    window.__nativeSetFormat = (next) => {
      if (next !== 'avcc' && next !== 'mjpeg') return;
      const current = localStorage.getItem('asc.simFormat') || pickFormat();
      if (current === next && session) return;
      localStorage.setItem('asc.simFormat', next);
      startSession(next);
    };
    window.__nativeToggleTheme = () => {
      setTheme(currentTheme() === 'light' ? 'dark' : 'light');
    };
    window.__nativeToggleActionable = () => {
      const next = !actionableEnabled();
      setActionable(next);
      reflectActionable();
      remountFrame();
    };
    window.__nativeToggleLogs = () => toggleLogs();
    window.__nativeToggleAx = () => {
      if (!axInspector) return;
      if (axInspector.isEnabled()) axInspector.disable();
      else axInspector.enable();
    };
    // Queue-mode toggle: enable overlay in select-mode AND open the
    // Activity sheet + selection composer. Wired by review-client.js's
    // toggleQueueMode hook which manages dock visibility.
    window.__nativeToggleQueue = () => {
      if (!window.AgentSimReviewClient || !window.AgentSimReviewClient.toggleQueueMode) return;
      const btn = document.getElementById('nativeQueueToggle');
      const willEnable = !(btn && btn.classList.contains('active'));
      window.AgentSimReviewClient.toggleQueueMode(willEnable);
      if (btn) btn.classList.toggle('active', willEnable);
    };
    // Sidebar-view jump — bounce out of focus mode and into the
    // inline `startStream` layout on `/simulators`. The hash is
    // the cue sim-stream.js reads on load to auto-open the same
    // device's stream view without an extra click.
    window.__nativeOpenSidebarView = () => {
      location.href = '/simulators#stream=' + encodeURIComponent(udid);
    };

    // Orientation cycle — one click advances 90° CW. Cycle length
    // varies by device class: 3 on iPhone (skips upside-down,
    // which iPhone UIKit ignores), 4 on iPad. POSTs the new value
    // through the `/simulators/<udid>/orientation?value=...` route;
    // server delegates to `simulator.orientation().set(...)`, which
    // fires a GSEvent over PurpleWorkspacePort.
    window.__nativeRotate = () => {
      const cycle = orientationCycle();
      orientationIndex = (orientationIndex + 1) % cycle.length;
      const value = cycle[orientationIndex];
      // Mirror the rotation in the UI immediately. The CSS
      // transform on `#nativeDeviceFrame > div` rotates the bezel
      // + canvas as one unit, while the input + overlay wrappers
      // remap coords back to portrait so taps still land on the
      // iOS element under the cursor.
      applyOrientation(value);
      const url = '/simulators/' + encodeURIComponent(udid)
          + '/orientation?value=' + encodeURIComponent(value);
      fetch(url, { method: 'POST' }).catch(() => { /* best-effort */ });
    };
  }

  // Surface a selected AX node in the floating `#nativeAxHost`
  // panel. Wraps the inspector's static selection renderer with a
  // header (title + close) so the panel can be dismissed without
  // disabling the inspector itself.
  function renderAxPanel(panel, node) {
    if (!panel) return;
    if (!node) {
      panel.removeAttribute('data-open');
      panel.innerHTML = '';
      return;
    }
    panel.setAttribute('data-open', 'true');
    panel.innerHTML =
        '<div class="ax-host-head">' +
        '<span>Element</span>' +
        '<button class="ax-host-close" data-role="ax-close" aria-label="Dismiss">×</button>' +
        '</div>' +
        '<div data-role="ax-body"></div>';
    panel.querySelector('[data-role="ax-close"]').addEventListener('click', () => {
      panel.removeAttribute('data-open');
      panel.innerHTML = '';
    });
    window.AXInspector.renderSelectionInto(
        panel.querySelector('[data-role="ax-body"]'),
        node,
        {
          send: (payload) => session && session.send(payload),
          getDeviceSize: () => frame.screenSize(),
        }
    );
  }

  // --- Bottom dock: activity drawer + chat-to-queue composer -------
  // The on-the-move screen is just: live stream + AX element picker +
  // this dock. The dock is one fixed glass bar at the bottom holding
  // a collapsible Activity drawer (the inbox: what's queued vs picked
  // up) above the composer. Typing a message + send POSTs to the
  // session-less notes queue (`POST /notes`); if an AX element is
  // picked its `_path` rides along so the note is anchored to the
  // tapped element — promotable later into a review task. No session,
  // no task id; the inbox is `GET /notes.json`.
  function injectBottomDock() {
    const root = document.getElementById('simNativeView');
    if (!root || document.getElementById('nativeBottomDock')) return;
    const dock = document.createElement('div');
    dock.id = 'nativeBottomDock';
    root.appendChild(dock);
    injectActivityDrawer(dock);
    injectQueueComposer(dock);
  }

  // Collapsible Activity drawer. Header is a button (counts +
  // chevron) that shrinks/expands the list so the user can keep an
  // eye on what's in progress without giving up the device view.
  // Collapsed by default — the device stays as big as possible; the
  // header still shows live counts.
  const ACTIVITY_OPEN_KEY = 'agentsim.activityOpen';
  function injectActivityDrawer(dock) {
    const sec = document.createElement('section');
    sec.id = 'nativeActivity';
    sec.innerHTML =
        '<button type="button" id="naqToggle" class="naq-head" ' +
          'aria-label="Toggle activity">' +
          '<svg class="naq-chev" viewBox="0 0 24 24" fill="none" ' +
            'stroke="currentColor" stroke-width="2" stroke-linecap="round" ' +
            'stroke-linejoin="round" width="14" height="14">' +
            '<polyline points="6 9 12 15 18 9"/>' +
          '</svg>' +
          '<span class="naq-title">Activity</span>' +
          '<span class="naq-counts" data-role="naq-counts">—</span>' +
        '</button>' +
        '<div class="naq-list" data-role="naq-list"></div>';
    dock.appendChild(sec);
    const open = localStorage.getItem(ACTIVITY_OPEN_KEY) === '1';
    if (open) sec.setAttribute('data-open', 'true');
    document.getElementById('naqToggle').addEventListener('click', () => {
      const isOpen = sec.getAttribute('data-open') === 'true';
      setActivityOpen(!isOpen);
    });
  }

  function setActivityOpen(open) {
    const sec = document.getElementById('nativeActivity');
    if (!sec) return;
    if (open) {
      sec.setAttribute('data-open', 'true');
      localStorage.setItem(ACTIVITY_OPEN_KEY, '1');
      refreshActivity();
    } else {
      sec.removeAttribute('data-open');
      localStorage.removeItem(ACTIVITY_OPEN_KEY);
    }
  }

  // Poll the inbox every few seconds while the screen is open so the
  // drawer reflects notes other clients add and promotions picked up
  // by the review side. Always refreshes the header counts; only
  // re-renders the list body when the drawer is expanded.
  // Live by default: subscribe to `WS /notes/stream` so a note left
  // from anywhere (this composer, the `notes` CLI, another phone)
  // lands in the drawer within the server's 0.5 s diff tick. The
  // `/notes.json` poll is kept only as a fallback while the socket is
  // down — one immediate fetch for first paint, then a slow 8 s
  // backstop that the socket clears the moment it delivers.
  function startActivityPolling() {
    refreshActivity();
    connectActivityStream();
  }

  function connectActivityStream() {
    let ws;
    try {
      const loc = window.location;
      const proto = loc.protocol === 'https:' ? 'wss:' : 'ws:';
      ws = new WebSocket(proto + '//' + loc.host + '/notes/stream');
    } catch (_) { startActivityFallback(); return; }
    activityStream = ws;
    ws.onopen = () => { stopActivityFallback(); };
    ws.onmessage = (ev) => {
      let env;
      try { env = JSON.parse(ev.data); } catch (_) { return; }
      if (!env || env.type !== 'notes_snapshot') return;
      renderActivity(Array.isArray(env.notes) ? env.notes : []);
    };
    ws.onclose = () => {
      activityStream = null;
      if (activityClosed) return;
      startActivityFallback();
      activityReconnect = setTimeout(connectActivityStream, 3000);
    };
    ws.onerror = () => { try { ws.close(); } catch (_) { /* ignore */ } };
  }

  function startActivityFallback() {
    if (activityTimer) return;
    activityTimer = setInterval(refreshActivity, 8000);
  }

  function stopActivityFallback() {
    if (!activityTimer) return;
    clearInterval(activityTimer);
    activityTimer = null;
  }

  async function refreshActivity() {
    let notes = [];
    try {
      const r = await fetch('/notes.json', { cache: 'no-store' });
      if (r.ok) notes = await r.json();
    } catch (_) { return; /* keep the last good render */ }
    renderActivity(Array.isArray(notes) ? notes : []);
  }

  // Paint header counts always; only re-render the (potentially long)
  // list body when the drawer is actually expanded.
  function renderActivity(notes) {
    const queued = notes.filter((n) => !n.promoted).length;
    const picked = notes.filter((n) => n.promoted).length;
    const counts = document.querySelector('[data-role="naq-counts"]');
    if (counts) {
      counts.textContent = notes.length
          ? `${queued} queued · ${picked} picked up`
          : 'empty';
    }
    const sec = document.getElementById('nativeActivity');
    if (sec && sec.getAttribute('data-open') === 'true') {
      renderActivityList(notes);
    }
  }

  function renderActivityList(notes) {
    const list = document.querySelector('[data-role="naq-list"]');
    if (!list) return;
    if (!notes.length) {
      list.innerHTML = '<div class="naq-empty">No messages yet. ' +
          'Pick an element and leave one below.</div>';
      return;
    }
    list.innerHTML = notes.map((n) => {
      const picked = !!n.promoted;
      const badge = picked
          ? '<span class="naq-badge picked">Picked up</span>'
          : '<span class="naq-badge queued">Queued</span>';
      const anchor = n.axPath
          ? '<span class="naq-anchor" title="' + esc(n.axPath) + '">⌖ '
              + esc(shortPath(n.axPath)) + '</span>'
          : '';
      return '<div class="naq-item' + (picked ? ' is-picked' : '') + '">' +
               '<div class="naq-item-top">' + badge +
                 '<span class="naq-time">' + esc(relativeTime(n.createdAt))
                 + '</span></div>' +
               '<div class="naq-text">' + esc(n.text || '') + '</div>' +
               anchor +
             '</div>';
    }).join('');
  }

  function esc(s) {
    return String(s == null ? '' : s)
        .replace(/&/g, '&amp;').replace(/</g, '&lt;')
        .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  // Trim a JSON-pointer-ish AX path to its tail so it fits the chip.
  function shortPath(p) {
    const parts = String(p || '').split('/').filter(Boolean);
    return parts.length <= 2 ? p : '…/' + parts.slice(-2).join('/');
  }

  function relativeTime(iso) {
    const t = Date.parse(iso);
    if (!Number.isFinite(t)) return '';
    const s = Math.max(0, Math.round((Date.now() - t) / 1000));
    if (s < 45) return 'just now';
    const m = Math.round(s / 60);
    if (m < 60) return m + 'm ago';
    const h = Math.round(m / 60);
    if (h < 24) return h + 'h ago';
    return Math.round(h / 24) + 'd ago';
  }

  function injectQueueComposer(dock) {
    if (document.getElementById('nativeQueueComposer')) return;
    const form = document.createElement('form');
    form.id = 'nativeQueueComposer';
    form.setAttribute('autocomplete', 'off');
    form.innerHTML =
        '<div id="nqcContext" class="nqc-context" hidden>' +
          '<span class="nqc-ctx-dot"></span>' +
          '<span class="nqc-ctx-label" data-role="nqc-ctx-label"></span>' +
          '<button type="button" class="nqc-ctx-clear" data-role="nqc-ctx-clear" ' +
            'aria-label="Detach element">×</button>' +
        '</div>' +
        '<div class="nqc-row">' +
          '<input id="nqcInput" class="nqc-input" type="text" ' +
            'placeholder="Leave a message for the queue…" ' +
            'enterkeyhint="send" autocapitalize="sentences" />' +
          '<button id="nqcSend" class="nqc-send" type="submit" ' +
            'aria-label="Add to queue">' +
            '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
              'stroke-width="2" stroke-linecap="round" stroke-linejoin="round" ' +
              'width="18" height="18">' +
              '<path d="M4 12 20 4 14 20l-3-7z"/>' +
            '</svg>' +
          '</button>' +
        '</div>' +
        '<div id="nqcStatus" class="nqc-status" role="status"></div>';
    dock.appendChild(form);
    form.addEventListener('submit', (e) => { e.preventDefault(); submitNote(); });
    form.querySelector('[data-role="nqc-ctx-clear"]')
        .addEventListener('click', () => {
          lastAxNode = null;
          if (axInspector) try { axInspector.clearSelections(); } catch (_) {}
          renderAxPanel(document.getElementById('nativeAxHost'), null);
          updateComposerContext();
        });
    updateComposerContext();
  }

  // Reflect the picked AX element as a chip above the input so the
  // user can see what their next note will be anchored to (and detach
  // it). Falls back to "No element — note will be unanchored".
  function updateComposerContext() {
    const ctx = document.getElementById('nqcContext');
    if (!ctx) return;
    const label = ctx.querySelector('[data-role="nqc-ctx-label"]');
    if (lastAxNode && (lastAxNode.label || lastAxNode.role || lastAxNode._path)) {
      const name = lastAxNode.label || lastAxNode.role || 'element';
      const role = lastAxNode.role && lastAxNode.label ? ' · ' + lastAxNode.role : '';
      if (label) label.textContent = name + role;
      ctx.hidden = false;
    } else {
      ctx.hidden = true;
    }
  }

  function setComposerStatus(text, kind) {
    const el = document.getElementById('nqcStatus');
    if (!el) return;
    el.textContent = text || '';
    el.dataset.kind = kind || '';
  }

  // POST the message onto the session-less notes queue. axPath rides
  // along when an element is picked. On success: clear the input,
  // drop the anchor, flash a confirmation. The note is now in the
  // inbox (`GET /notes.json`) and promotable to a review task.
  async function submitNote() {
    const input = document.getElementById('nqcInput');
    const send = document.getElementById('nqcSend');
    if (!input) return;
    const text = input.value.trim();
    if (!text) { input.focus(); return; }
    if (send) send.disabled = true;
    setComposerStatus('Sending…', '');
    try {
      const body = { udid, text };
      if (lastAxNode && lastAxNode._path) body.axPath = lastAxNode._path;
      const r = await fetch('/notes', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (!r.ok) throw new Error('HTTP ' + r.status);
      input.value = '';
      lastAxNode = null;
      if (axInspector) try { axInspector.clearSelections(); } catch (_) {}
      renderAxPanel(document.getElementById('nativeAxHost'), null);
      updateComposerContext();
      setComposerStatus('Added to queue', 'ok');
      setTimeout(() => setComposerStatus('', ''), 2400);
      refreshActivity();
    } catch (err) {
      setComposerStatus('Could not send — tap to retry', 'err');
      console.warn('[native] note submit failed', err);
    } finally {
      if (send) send.disabled = false;
    }
  }

  // Log sheet: lazy-mount on first open, leave the LogPanel attached
  // across subsequent toggles so a "close → reopen" doesn't drop the
  // backlog. Only `unmount` on page unload (or explicit close button
  // — same code path). The toolbar button toggles the
  // `[data-logs="open"]` attribute on `#simNativeView`; CSS handles
  // the slide-up animation and visibility.
  function toggleLogs() {
    const view = document.getElementById('simNativeView');
    const host = document.getElementById('nativeLogsHost');
    const btn  = document.getElementById('nativeLogsToggle');
    const open = view && view.getAttribute('data-logs') === 'open';
    if (!view || !host) return;
    if (open) {
      view.removeAttribute('data-logs');
      if (btn) btn.classList.remove('active');
    } else {
      view.setAttribute('data-logs', 'open');
      if (btn) btn.classList.add('active');
      if (!logPanel && window.LogPanel && udid) {
        host.innerHTML = '';
        logPanel = new window.LogPanel(host, { udid, level: 'info' });
      }
    }
  }

  // Re-mount the device frame after the actionable toggle flips. Tear
  // down current input wiring + bezel buttons, rebuild the frame in
  // the new mode, and re-bind a fresh SimInput chain over the new
  // surface. The live stream stays open — the canvas is the same
  // element, only the bezel image and overlays change.
  function remountFrame() {
    if (!frame) return;
    if (mouseSource) { try { mouseSource.detach(); } catch (_) {} mouseSource = null; }
    if (touchSource) { try { touchSource.detach(); } catch (_) {} touchSource = null; }
    if (pinchOverlay) { try { pinchOverlay.clear(); } catch (_) {} pinchOverlay = null; }
    if (keyboardCapture) { try { keyboardCapture.stop(); } catch (_) {} keyboardCapture = null; }
    if (surface && surface.bezelButtons) {
      try { surface.bezelButtons.unmount(); } catch (_) { /* ignore */ }
    }
    frame = new window.DeviceFrame({
      udid, layout,
      actionable: actionableEnabled(),
      onPress: (name, duration) => simInput && simInput.button(name, duration),
    });
    surface = frame.mount(document.getElementById('nativeDeviceFrame'));
    // StreamSession captures the canvas at construction; the
    // remount produced a fresh canvas so we have to reopen the
    // session against it. Reuse the format the user already chose.
    startSession(pickFormat());
    wireKeyboard();
  }

  function reflectActionable() {
    const btn = document.getElementById('nativeActionableToggle');
    if (btn) btn.classList.toggle('active', actionableEnabled());
  }

  function wireUnload() {
    window.addEventListener('beforeunload', () => {
      try { if (session) session.stop(); } catch (_) { /* ignore */ }
      try { if (mouseSource) mouseSource.detach(); } catch (_) { /* ignore */ }
      try { if (touchSource) touchSource.detach(); } catch (_) { /* ignore */ }
      try { if (keyboardCapture) keyboardCapture.stop(); } catch (_) { /* ignore */ }
      try { if (axInspector) axInspector.detach(); } catch (_) { /* ignore */ }
      activityClosed = true;
      try { if (activityTimer) clearInterval(activityTimer); } catch (_) { /* ignore */ }
      try { if (activityReconnect) clearTimeout(activityReconnect); } catch (_) { /* ignore */ }
      try { if (activityStream) activityStream.close(); } catch (_) { /* ignore */ }
    });
  }

  // Take a snapshot from the live canvas and trigger a download. We
  // skip CaptureGallery here — the focus chrome has nowhere to put a
  // thumbnail strip, and the user just wants the file.
  function downloadSnapshot() {
    if (!surface || !surface.canvas) return;
    const w = lastPaintedSize.w || surface.canvas.width;
    const h = lastPaintedSize.h || surface.canvas.height;
    if (!w || !h) return;
    surface.canvas.toBlob((blob) => {
      if (!blob) return;
      const stamp = new Date().toISOString().replace(/[:.]/g, '-');
      const safe = (deviceName || 'simulator').replace(/[^A-Za-z0-9._-]/g, '_');
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = `${safe}-${stamp}.png`;
      document.body.appendChild(a);
      a.click();
      requestAnimationFrame(() => {
        URL.revokeObjectURL(a.href);
        a.remove();
      });
    }, 'image/png');
  }

  console.log('[agent-sim] sim-native.js active for', udid);
})();
