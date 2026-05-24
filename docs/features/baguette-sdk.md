# Baguette JS SDK

The Baguette SDK is the **browser-side library** that exposes a domain-shaped, OCP/SRP-clean interface for driving a simulator. Replaces the page-level transaction scripts (`bezel-buttons.js`, `sim-input.js`, `sim-input-bridge.js`) with a thin composition root: consumer pages call `Baguette.use(...)` and `sim.mount(...)`; everything else is internal.

This document captures the SDK shape, the `/simulators/<UDID>/definition.json` bootstrap endpoint that feeds it, and the path from "transaction script" to "rich domain model" that motivated the refactor.

---

## Public API — the entire surface

```js
import { Baguette } from '/baguette/baguette.js';   // or window.Baguette

// "I want to use this iPhone simulator."
const sim = await Baguette.use({
  host: location.origin,      // baguette server origin
  udid: '...',                // simulator UDID
  send: (payload) => ws.send(JSON.stringify(payload)),  // wire sink
  log: (msg, isErr) => { ... },
});

// "Make it interactive."
sim.mount(document.getElementById('host'));

// Drive the model directly (advanced — same wire envelopes the
// gesture interpreter emits, type-safe, no JSON):
sim.screen.tap({ x: 100, y: 200 });
sim.screen.swipe({ from, to, duration: 0.25 });
sim.buttons[0].press({ hold: 1.5 });
sim.button('powerButton').press({ hold: 1.5 });    // by id

// Cleanup
sim.detach();
```

That's the whole consumer surface. No wire envelopes. No JSON shapes. No DOM math. No `kind:` discriminators. Adding a new device family doesn't change one line of the page code that calls this.

---

## Wire bootstrap — `/simulators/<UDID>/definition.json`

The SDK's first call: a per-simulator description of which parts the simulator has, computed by Swift from the device's `chrome.json` plus identity.

```json
{
  "identity": {
    "udid":  "1234-...",
    "name":  "iPhone 17 Pro",
    "model": "iPhone 17 Pro"
  },
  "screen": {
    "viewport":   { "width": 436, "height": 906 },
    "rect":       { "x": 22, "y": 22, "width": 392, "height": 862 },
    "clipRadius": 56,
    "bezelImage": {
      "rest": "/simulators/1234-.../bezel.png",
      "bare": "/simulators/1234-.../bezel.png?buttons=false"
    }
  },
  "buttons": [
    {
      "id":       "powerButton",
      "envelope": { "type": "button", "button": "power" },
      "images":   {
        "rest":    "/simulators/1234-.../chrome-button/powerButton.png",
        "pressed": "/simulators/1234-.../chrome-button/powerButton-down.png"
      },
      "z": "below"
    },
    { "id": "volumeUp", "envelope": {"type":"button","button":"volume-up"}, ... }
  ]
}
```

Optional fields arrive on devices that have them:

- `"crown": { ... }` — Apple Watch's Digital Crown (rotary + click)
- `"keyboard": { ... }` — software keyboard input
- `"remote": { ... }` — Apple TV's Siri Remote (future)

**No `kind:` tagged-union.** Parts are member fields. The JS SDK constructs a `Crown` part if `def.crown` is present, a `Keyboard` part if `def.keyboard` is present, otherwise skips. Watch's Digital Crown is its own class with `rotate()` + `click()` — never confused with a press button.

---

## Module layout

```
Resources/Web/baguette/
├── baguette.js                 ← entry: Baguette.use(...) / Baguette.version
├── transport.js                ← THE ONE file that knows the wire format
├── simulator.js                ← facade. composes parts, owns lifecycle
├── parts/
│   ├── bezel.js                ← bezel image + screen-rect clip
│   ├── screen.js               ← tap/swipe/touch verbs + frame canvas
│   ├── button.js               ← one hardware button (mousedown→press)
│   ├── crown.js                ← Apple Watch — rotate/click  (future)
│   └── keyboard.js             ← type/key + codeMap          (future)
└── gestures/
    └── pointer-interpreter.js  ← DOM events → Screen domain methods
```

### SRP — one class, one reason to change

| Concern | File |
|---|---|
| Wire dialect | `transport.js` only |
| Bezel rendering | `parts/bezel.js` only |
| Pointer events → gestures | `gestures/pointer-interpreter.js` only |
| Hardware button DOM + animation | `parts/button.js` only |
| Composition lifecycle | `simulator.js` only |

### OCP — extension without modification

| Change | What touches |
|---|---|
| Add a new screen verb (e.g. `pinch`) | `parts/screen.js` |
| New hardware button on iPhone | Data only — `compose(...)` projects it |
| Apple Watch support | Add `parts/crown.js` + the Swift definition adds `crown` field |
| Apple TV support | Add `parts/remote.js`; facade reads `def.remote`; Screen part not instantiated |
| Page redesign | Consumer pages only — SDK untouched |

Every column ends in *one* file.

---

## How the layers talk

```
Consumer page                Baguette SDK                       Baguette server
─────────────────            ─────────────────                   ───────────────
                                                                /simulators/<udid>/definition.json
const sim = await    ──fetch──>                       ────GET───>     │
  Baguette.use({...})                                                  │
                              new Simulator(def, ...) <───JSON─────────┘
                                creates parts:
                                 • Screen
                                 • Button × N
                                 • Crown?, Keyboard?

sim.mount(container) ──────── Bezel.mount renders                ws://.../stream
                              Screen.bindDOM attaches            (page-owned WS)
                              PointerInterpreter                        ▲
                              Button.mount × N                          │
                                                                        │
user clicks power button ──── Button.press({hold: 1.5})                 │
                                ↓                                       │
                              transport.button(envelope, ...)           │
                                ↓                                       │
                              send({type:"button",button:"power", ──────┘
                                    duration: 1.5})
```

The SDK never opens its own WebSocket. The consumer page owns transport lifecycle (already needs the socket for frame streaming) and hands its `send(payload)` callback to `Baguette.use`. Cleanly separates transport from model — the SDK is socket-agnostic.

---

## First-principle anchor

A simulator stands in for a physical device. A physical device is composed of parts. Each part has behaviors. The user interacts with the parts. That's the whole domain — three nouns: **device**, **parts**, **behaviors**. Different devices have different parts. iPhone has `screen + buttons + keyboard`. Watch has `screen + buttons + crown + keyboard`. Apple TV has no screen-as-input-surface — it has a remote.

The SDK mirrors that shape in both languages: the Swift `Simulator` has sub-aggregates; the JS `Simulator` has the same sub-objects. Wire envelopes are a remoting detail, not a domain concern.

---

## Migration path

1. **(landed)** SDK skeleton + `/definition.json` route + `/baguette-demo.html` smoke page. Existing pages untouched.
2. **(next)** Cutover `sim-native.js` to `Baguette.use().mount()`. Keep `StreamSession` for frames; SDK takes over bezel + buttons + tap dispatch.
3. **(next)** Port `MouseGestureSource` logic into `gestures/pointer-interpreter.js` — drag, pinch, edge gestures, wheel synthesis. Delete `sim-input.js`.
4. **(next)** Cutover `sim-stream.js` + `farm/farm-tile.js`. Delete `sim-input-bridge.js`, `bezel-buttons.js`, `device-frame.js`.
5. **(next)** Add `parts/crown.js` + `parts/keyboard.js`. Apple Watch correctness lands.
6. **(eventually)** Add `parts/remote.js` for Apple TV. Vision Pro adds whatever parts it needs.

Each step is bounded — the SDK boundary means a page cutover is "delete N old files, change 5 lines in the page, done."

---

## Adding a new part type

1. **Swift**: add the optional field to `SimulatorDefinition` (Domain/Simulator/SimulatorDefinition.swift).
2. **Swift**: extend `SimulatorDefinition.compose(...)` to project the new part from `DeviceChromeAssets` (or wherever its data lives).
3. **Swift**: add tests in `Tests/BaguetteTests/Simulator/SimulatorDefinitionTests.swift` (TDD per CLAUDE.md).
4. **JS**: add `parts/<thing>.js` exporting a class with the part's domain verbs.
5. **JS**: instantiate it in `simulator.js` when the field is present.
6. **HTML**: include the new `<script>` in `sim.html` (and demo page).

Consumer pages, transport, and other parts don't change.

---

## Why this isn't a "data-driven UI"

Earlier proposals shipped a tagged-union "scene with controls[]" and had a `Mounts[cap.kind]` registry on the JS side that interpreted the data. That was the **transaction script smell at a different layer** — frontend still had to know "a `buttons` capability becomes `<button>` overlays, a `crown` capability becomes a wheel listener."

The current SDK doesn't have a `kind:` switch anywhere. Parts are member fields; the Simulator constructor instantiates a part class iff the field is present; each part class owns its rendering AND its wire dispatch. The view layer asks parts to render themselves; nobody interprets a config. **That's why the SDK boundary holds across new device families.**
