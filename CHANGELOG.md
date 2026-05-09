# Changelog

All notable changes to baguette will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

For releases prior to this changelog, see the
[GitHub Releases](https://github.com/tddworks/baguette/releases) page.

## [Unreleased]

### Added
- **Device orientation (`orientation`).** New `baguette orientation --udid <UDID> <portrait|landscape-left|landscape-right|portrait-upside-down>` CLI subcommand, `POST /simulators/:udid/orientation?value=<…>` HTTP route, and a single rotate icon in the focus-mode toolbar that cycles the device 90° clockwise on each click. All three surfaces feed `simulator.orientation().set(_:)`, which fires a `GSEventTypeDeviceOrientationChanged` mach message at the booted simulator's `PurpleWorkspacePort` — bypassing SimulatorKit's NSView path entirely so the host stays headless. Wire format (112-byte buffer, `msgh_size = 108`, `msgh_id = 0x7B`, GSEvent type `50 | 0x20000` at offset `0x18`, `UIDeviceOrientation` raw value at `0x4C`) is reverse-engineered from `Simulator.app`'s `[SimDevice(GSEvents) gsEventsSendOrientation:]` and matches idb's `PrivateHeaders/SimulatorApp/GSEvent.h`. iPhone UIKit silently ignores `portrait-upside-down` for apps that don't declare `UIInterfaceOrientationPortraitUpsideDown` (which is most Apple-shipped apps including SpringBoard / Photos / Settings) — Domain / CLI / HTTP still accept the value unconditionally, but the browser cycle button drops it on iPhone (3-step on phones via `chrome.json.identifier` prefix, 4-step on tablets) so every click visibly rotates.
- **Stream button on `/simulators` opens focus mode.** Clicking **Stream** in the simulator list now navigates to `/simulators/<UDID>` (the focus-mode page owned by `sim-native.js`) instead of swapping the inline `#simPluginView` in place. Browser back returns to the list, the URL is shareable, and the inline-view flash is gone. Inverse trip: a glass-pill **sidebar view** button at the bottom-left of focus mode (mirror of the theme toggle) navigates back to `/simulators#stream=<UDID>`; `sim-stream.js` reads the hash on load, fetches the device name, strips the hash, and auto-opens the inline `startStream` layout — so the user lands in the sidebar view directly without an extra click.

- **`IOHIDDigitizerDispatch` — coordinate input + system gestures on iOS 26 / Xcode 26.** New unified dispatch path for taps, swipes, streaming `touch1-*` chains, and the home-indicator system gestures (swipe-to-home, app switcher). The Xcode 26 SDK ships an `IndigoHIDMessageForMouseNSEvent` that produces messages iOS either misroutes to the home gesture or silently drops; the new path bypasses the regression by feeding the simulator a real hardware-shaped `IOHIDEvent` instead. Recipe: build an `IOHIDEventCreateDigitizerEvent` parent with an `IOHIDEventCreateDigitizerFingerEvent` child appended via `IOHIDEventAppendEvent`, run it through `IndigoHIDMessageForTrackpadEventFromHIDEventRef` (the only `*FromHIDEventRef` wrapper that accepts digitizer events), then patch four byte slots the wrapper leaves uninitialised — `0x6c` / `0x10c` with `0x32` (`IndigoHIDTouchTarget`) and `0x3a/0x3b` / `0xda/0xdb` with the `IndigoHIDEdge` bitmask (left=`0x02`, right=`0x04`, top=`0x08`, **bottom=`0x01`**). Bitmask values were derived empirically by sweeping `edge=0..4` through the working mouse-event signature and diffing produced bytes. `IndigoHIDInput.tap`, `swipe`, `touch1` (with optional `edge` field), and the new `swipeToHome` / `appSwitcher` buttons all route through this path; iOS's home-indicator gesture recognizer fires correctly on edge-flagged drags, and velocity/dwell discriminate Home from App Switcher inside iOS exactly as `Simulator.app` does. Verified end-to-end on iPhone 17 Pro Max / iOS 26.4 / Xcode 26: tap → app launches, edge swipe → home, slow edge drag with dwell → app-switcher cards. See [`docs/features/touches.md`](docs/features/touches.md) for the full recipe and the `diag-digitizer-trackpad` falsification probe.
- **`touch1-*` envelopes carry an optional `edge` field.** `bottom` / `top` / `left` / `right` flag every event in a streaming chain as a screen-edge system gesture. The browser focus-mode canvas auto-detects bottom-edge mousedown (drag start at `y/r.height ≥ 0.93`) and switches to live `touch1-*` streaming with `edge: "bottom"`, so iOS animates the home-card preview in real time as the user drags — same UX as dragging in `Simulator.app`, no client-side discriminator or buffered playback on release.
- **`app-switcher` and `swipe-to-home` virtual buttons.** Two new `Press`-compatible wire names route through `baguette press --udid …`, the wire JSON `{"type":"button"}`, the browser's `simInput.button(...)` bridge, and the focus-mode toolbar. Both ride the new digitizer dispatch with `edge=bottom`: `swipe-to-home` synthesizes a fast edge-flick (~12 × 16 ms steps to `y=0.30`); `app-switcher` synthesizes a slow drag-and-hold (~30 × 35 ms steps to `y=0.58` + 900 ms dwell). Use them when the agent wants the gesture vocabulary without managing a streaming chain manually; use streaming `touch1-*` with `edge: "bottom"` when the UI needs iOS's live preview during the drag.
- **Edge gestures fire in all four orientations.** The browser's orientation transport now rotates the `edge` flag alongside the touch coordinates so iOS's home-indicator gesture recognizer sees the correct physical-edge bit for the current rotation. Verified mapping for a visual-bottom drag: `portrait` → wire `bottom`, `landscape-left` (raw=4) → wire `right`, `portrait-upside-down` (raw=2) → wire `right`, `landscape-right` (raw=3) → wire `top`. CLI / wire callers still pass the device-frame edge directly; the orientation-aware remap is browser-side only.
- **Pull-down from the top edge opens the Lock Screen / Notification Center.** The browser canvas now detects a top-edge mousedown (`y / r.height ≤ 0.07`) the same way it detects a bottom-edge drag, and switches to live `touch1-*` streaming with `edge: "top"`. iOS's status-bar recognizer routes the swipe based on the start-x coordinate exactly like Simulator.app does — top-LEFT origin pulls the lock-screen cover sheet down, top-RIGHT origin opens Notification Center. Same UX as the bottom-edge home / app-switcher streaming: no client-side discriminator, iOS animates the cover sheet live as the cursor drags. Two new `Press`-compatible wire names back the canned shapes for CLI / scripting: `pull-down-to-lock-screen` (slow drag from `(0.25, 0.002)` to `(0.25, 0.55)` with `edge=top`) and `pull-down-to-notification-center` (slow drag from `(0.75, 0.002)` to `(0.75, 0.55)` with `edge=top`). Both ride `IOHIDDigitizerDispatch`.

### Fixed
- **App-switcher button no longer locks the screen ([#5](https://github.com/tddworks/baguette/issues/5)).** The third icon in the focus-mode toolbar carries the two-overlapping-squares glyph that mirrors `Simulator.app`'s app-switcher button, but it was wired to `simInput.button('lock')` — every click locked the device instead. The click now fires `simInput.button('app-switcher')` against the new virtual button described above. Lock remains reachable via `baguette press --udid … --button lock`; the focus-mode toolbar now matches `Simulator.app`'s Home / Screenshot / App Switcher trio.

### Changed
- **`app-switcher` button now rides the home-press recipe; the slow swipe-and-hold variant moves to `swipe-to-app-switcher`.** Originally `app-switcher` synthesized a slow edge-flagged drag from the home indicator with a 900 ms dwell at `y=0.58` and let iOS's home-indicator recognizer fire the multitasking carousel. That works but depends on the gesture path's velocity / dwell heuristics and rides the same digitizer dispatch as the home / lock-screen streams. `app-switcher` now decomposes into two consecutive `IndigoHIDMessageForButton` home presses ~150 ms apart — SpringBoard's own multitasking trigger, which fires on the home-button event source regardless of whether the device has physical home-button hardware. Cleaner, rotation-agnostic, and matches idb's `FBSimulatorPurpleHID` app-switcher path. The swipe-and-hold synthesis is preserved on the wire as a fifth virtual button, `swipe-to-app-switcher`, for callers that explicitly want the gesture path. Browser focus-mode toolbar's app-switcher icon now lands the home-press variant.

### Changed
- **`Simulator` is now a `@Mockable` protocol; `Simulators` is a true DDD repository.** The struct-with-`host`-delegation pattern grew to seven capability methods (`screen`, `input`, `accessibility`, `logs`, `orientation`, `boot`, `shutdown`) all parked on the aggregate, which read as a god-object. The aggregate now exposes only `all` / `find(udid:)` (plus the `running` / `available` / `listJSON` extensions); per-simulator capabilities live on the entity itself, owned by a new concrete `CoreSimulator` (Infrastructure) that holds a `DeviceHost` reference and resolves a fresh `SimDevice` on each operation. Domain default-impl extensions cover `canStream`, `canAcceptInput`, `json`, and `chrome(in:)`; identity getters and the new `SimulatorState` enum (lifted from the nested `Simulator.State`) are protocol contracts, not stored fields. Tests collapsed accordingly — 11 tautological / aggregate-delegation tests deleted, capability tests now drive `MockSimulator` directly via Mockable's auto-generated mock instead of `MockSimulators.screen(for: .value(s))`. CLI, HTTP, and browser surfaces are unchanged; this is a Domain rework only, motivated by giving each new capability (orientation just shipped, more coming) a stable home.
- **Boot in the simulator list no longer flashes the table.** Clicking **Boot** previously set `state.loading = true; render()` immediately, which wiped the device table and replaced it with a "Loading simulators…" placeholder before the POST even returned — the result felt like a full page refresh. The list now tracks per-device transition state in `state.pending` and shows an in-row "Booting…" / "Shutting down…" chip on just the affected row; the rest of the table stays put. The full-card placeholder is reserved for the *initial* fetch (`state.devices.length === 0`), so subsequent reloads (including the post-boot refresh) leave the existing list visible and only swap the row that changed.

---

## [0.1.68] - 2026-05-08

### Added
- **Accessibility inspector overlay in the browser UI.** Hovering the live stream now highlights the AX node under the cursor with a translucent box + role/label tooltip; clicking locks the selection and exposes **Copy id** / **Copy JSON** / **Tap (cx, cy)** actions. Two surfaces share one inspector module: a sidebar checkbox card on `/simulators` (sidebar mode) and a toolbar icon next to the bezel-actionable toggle on `/simulators/<UDID>` (focus mode), with selection details surfacing in a glass-styled floating panel anchored top-right of the device column. Hit-testing runs client-side against a cached AX tree (mirroring `AXNode.hitTest` on the Swift side, so the browser overlay and the `describe-ui --x --y` CLI always pick the same element). The cache is refreshed on every fresh hover (mouseenter on the screen) and every click — no polling timer; idle pages cost nothing. Reuses the existing `/simulators/:udid/stream` WebSocket (sends `{"type":"describe_ui"}`, receives `{"type":"describe_ui_result","ok":true,"tree":…}`); no new endpoints, no extra connections. The "Tap" button forwards the centre of the locked frame as a canonical `{"type":"tap","x":…,"y":…,"width":…,"height":…}` envelope, so the inspector composes with every gesture path. See [`docs/features/ax-inspector.md`](docs/features/ax-inspector.md).

### Changed
- **Logs panel no longer stalls the page under CoreDuet-chatter floods.** Server-side `LogBatcher` (`Domain/Logs/LogBatcher.swift`) coalesces emitted lines into bounded batches that flush either at a 200-line size cap or after a 50 ms time window, replacing the per-line `{"type":"log","line":"…"}` text frames with one `{"type":"log","lines":["…","…"]}` envelope per ~20 frames/sec; clients still tolerate the old single-line shape during rolling upgrades. The browser-side `LogPanel` (`Resources/Web/sim-logs.js`) now renders incrementally — only newly arrived lines pay the regex-colourize cost on a `DocumentFragment`-driven append, instead of `innerHTML`-rebuilding the whole 1500-row buffer per frame; filter / clear / level / reveal trigger a one-shot full rebuild. An `IntersectionObserver` pauses rendering entirely when the panel is hidden (collapsed sidebar, off-screen sheet) and does one rebuild on reveal. WS frame rate is now bounded at ~20/sec regardless of log volume, and per-frame DOM cost is O(new lines) instead of O(buffer). See [`docs/features/logs.md`](docs/features/logs.md).

---

## [0.1.67] - 2026-05-07

### Added
- **Live unified-log stream (`logs`).** New `baguette logs --udid <UDID> [--level …] [--style …] [--predicate …] [--bundle-id …]` CLI subcommand and dedicated `WS /simulators/:udid/logs?level=&style=&predicate=&bundleId=` socket stream the booted simulator's `os_log` output line-by-line, in real time. CLI writes one log line per stdout line and SIGINT (Ctrl-C) tears down cleanly; WS emits `{"type":"log","line":"<entry>"}` text frames bracketed by `log_started` / `log_stopped`. `--bundle-id` is a shorthand that translates to `process == "<id>"` and ANDs with an explicit `--predicate` when both are given. Adapter shells out to `xcrun simctl spawn <udid> log stream …` rather than calling `SimDevice.spawnWith…` directly — the direct path is published in CoreSimulator and *almost* works, but on iOS 26 the spawned `log` binary fails its `mbr_check_membership_ext("admin", …)` check unless the caller is Apple-signed (which `simctl` is and we aren't). simctl is guaranteed installed alongside our device set, so the indirection is cheap. Slimmer level set than the macOS host `log` binary: `default | info | debug` only — `notice / error / fault` are explicitly rejected at the wire because the iOS-runtime `log stream` doesn't accept them. See [`docs/features/logs.md`](docs/features/logs.md).
- **Accessibility tree extraction (`describe-ui`).** New `baguette describe-ui --udid <UDID> [--x <px> --y <px>]` CLI subcommand and `{"type":"describe_ui"}` WebSocket message dump the booted simulator's on-screen UI tree as JSON: per-node `role`, `label`, `value`, `identifier`, `frame` (in **device points**, ready to feed back into a `tap` envelope), plus `enabled` / `focused` / `hidden` traits and recursive `children`. Hit-test path returns the topmost AX element under a coordinate. Powered by the private `AccessibilityPlatformTranslation` framework's `AXPTranslator` — out of Simulator.app the tricky bit is wiring a `bridgeTokenDelegate` ourselves so the translator can route XPC requests to the right `SimDevice.sendAccessibilityRequestAsync:`; without that delegate every `frontmostApplication…` call returns `nil`. Cribbed the dispatcher pattern from `cameroncooke/AXe` and `Silbercue/SilbercueSwift`'s `AXPBridge.swift`. See [`docs/features/accessibility.md`](docs/features/accessibility.md).

### Fixed
- **Cloned simulators now resolve their bezel** ([#2](https://github.com/tddworks/baguette/issues/2)). `xcrun simctl clone` rewrites the device's display `name` (e.g. `iPhone 17 Pro Max` → `iPhone 17 pro max clone 1`), but `Simulator.chrome(in:)` was keying chrome lookup off that name — so `FileSystemChromeStore` searched for a non-existent `iPhone 17 pro max clone 1.simdevicetype` bundle and `/simulators/<udid>/chrome.json` + `/bezel.png` returned 404. `Simulator` now carries `deviceTypeName` (read from the live `SimDevice.deviceType.name`, which is stable across clones / renames) and chrome lookup keys off that. Falls back to the display `name` when the host doesn't supply one, so non-clones and existing tests behave identically.

---

## [0.1.66] - 2026-05-06

### Added
- **Hardware side buttons (action / volume-up / volume-down / power) on the wire and CLI.** Extended `DeviceButton` with the four arbitrary-HID side buttons and added `press(duration:on:)` so the rich domain owns its own dispatch. New CLI: `baguette press --button <name> [--duration <s>]` accepts the full set; the wire JSON gains an optional `duration` for long-press semantics ("Hold for Ring" on the action button, Siri / SOS on power, etc.). Routes through `IndigoHIDMessageForHIDArbitrary(target, page, usage, operation)` — the iOS-26-correct 4-arg shape, NOT the (page, usage, op, timestamp) signature some open-source loaders use. The browser bezel overlay measures real `mousedown` → `mouseup` and forwards the elapsed time, so click-and-hold on a side button just works. `siri` is still rejected (crashes `backboardd` through every known Indigo path). See [`docs/features/buttons.md`](docs/features/buttons.md).
- **Mac keyboard input on the wire, CLI, and web UI.** New `Key` / `TypeText` gestures and a focus-gated browser capture: when the device screen has focus, every supported keystroke is forwarded automatically; click out and the host browser shortcuts (Cmd+R, Cmd+T, …) work normally again. CLI mirrors the wire — `baguette key --code KeyA --modifiers shift,command [--duration <s>]` and `baguette type --text "hello"`. Phase 1 covers letters, digits, named specials (Enter / Escape / Backspace / Tab / Space / Arrow\*), US punctuation, and the four modifiers (shift / control / option / command); IME / non-Latin / emoji is deferred to phase 2's `IndigoHIDMessageForKeyboardNSEvent` path. Wire codes are W3C `KeyboardEvent.code` strings so the browser forwards events verbatim — no translation table on the JS side. Mounted on both focus mode (`/simulators/<udid>`) and the focused tile in the device farm. See [`docs/features/keyboard.md`](docs/features/keyboard.md).
- **`baguette list --json`** emits the same `{"running":[…],"available":[…]}` envelope that `/simulators.json` serves. Plain `baguette list` keeps its per-line projection so existing scripts that grep field-by-field don't break; `--json` opts into the structured shape for tools that want one parse + a `running` / `available` split. Reuses `Simulators.listJSON` so the CLI and HTTP outputs stay byte-identical.

### Changed
- **`/simulators` defaults to "All Runtimes"** so every booted simulator (e.g. iOS 26.2 alongside the latest 26.x) is visible on first load. The runtime dropdown now lists "All Runtimes" first, then "Latest Runtime", then individual runtimes; users who want only the latest can re-select it. Fixes a discoverability gap where a simulator booted on a non-latest runtime was hidden until the user scrolled the dropdown.

---

## [0.1.65] - 2026-05-04

### Changed
- Bug fixes and improvements.

---

## [0.1.64] - 2026-05-04

### Added
- **One-shot JPEG screenshot endpoint + CLI.** New `GET /simulators/:udid/screenshot.jpg[?quality=&scale=]` route on `baguette serve` returns the current framebuffer as `image/jpeg`, so embedding pages can refresh on demand with a plain `<img src="…?t=…">` — no WebSocket plumbing required. New `baguette screenshot --udid <UDID> [--output <path>] [--quality 0.85] [--scale 1]` CLI mirrors it; defaults write to stdout so it composes with shell redirection. Both share `ScreenSnapshot.capture(...)`: open Screen, await one IOSurface (2 s timeout with a single-shot guard for the timer / callback / start-throw race), encode via the existing `JPEGEncoder` + optional `Scaler`, stop. See [`docs/features/screenshot.md`](docs/features/screenshot.md).

---

## [0.1.63] - 2026-05-04

### Added
- **Focus mode at `/simulators/<udid>`** — visiting the deep-link URL directly now skips the device list and drops straight into a clean "play the simulator" view: the bezel takes the full viewport (height-driven) with a single floating glass toolbar above it, mirroring a SwiftUI `VStack { Toolbar; Device }`. The toolbar carries a clickable `‹ <name> · iOS <ver>` breadcrumb (back to list), an inline H.264 / MJPEG segmented control, action buttons (Home / Screenshot / App-switcher), and a live fps badge. Action buttons drive `SimInput.button(...)`; Screenshot grabs the live canvas and downloads a PNG. Reuses the existing `DeviceFrame`, `StreamSession`, `SimInput`, `MouseGestureSource`, and `PinchOverlay` modules — no new transport, no new server route. Lives in `Resources/Web/sim-native.html` + `sim-native.js`; loaded by `sim.html` and synchronously sets `window.__baguetteNativeMode` so `sim-list.js` bails out before painting the list shell.
- **Light + dark theme with manual toggle.** Focus mode tokenises every colour at `#simNativeView` (`--nv-page-bg`, `--nv-bar-bg`, `--nv-text`, …) and tracks `prefers-color-scheme` by default. A floating glass pill in the bottom-right corner (`__nativeToggleTheme`) lets the user pin a theme, persisted to `localStorage.baguette.simTheme`; the pinned attribute beats the media query so manual choice always wins over the OS preference. Sun icon shows in light theme, moon in dark.

### Changed
- **`SimInputBridge` is now shared by the single-device pages too.** `sim.html` loads `sim-input-bridge.js`, and both `sim-stream.js` (sidebar mode) and `sim-native.js` (focus mode) call `window.SimInputBridge.makeTransport(session, log)` instead of carrying private `toBaguetteWire` + `phasedTouchWire` copies. ~140 lines of duplicated dialect translation removed; `farm-tile.js`, `sim-stream.js`, and `sim-native.js` now share one source of truth for the SimInput → Baguette wire-format mapping.

---

## [0.1.62] - 2026-05-03

### Changed
- Bug fixes and improvements.

---

## [0.1.61] - 2026-05-03

### Fixed
- **`baguette serve` no longer fails to launch when Xcode lives outside `/Applications/Xcode.app`** ([#1](https://github.com/tddworks/baguette/issues/1)). Two layers:
  - **Link-time:** `Package.swift` was declaring `SimulatorKit` and `CoreSimulator` as `linkedFramework`s, which baked LC_LOAD_DYLIB entries that dyld had to resolve before `main()` ran — and the rpaths it baked alongside them only matched `/Applications/Xcode.app`. Users with Xcode at e.g. `/Applications/Xcode_26.app` got `Library not loaded: @rpath/SimulatorKit.framework` and an immediate abort. Nothing in `Sources/` actually `import`s either framework, so the entries (and their rpath / `-F` flags) are gone; the binary now starts cleanly anywhere.
  - **Runtime:** `CoreSimulators.developerDir()` blindly trusted `xcode-select -p`, which on many machines points at `/Library/Developer/CommandLineTools` (no SimulatorKit) — particularly after a user renames their Xcode bundle. The resolver now verifies that `SimulatorKit.framework` actually exists at the selected developer directory and, if not, scans `/Applications` for any `Xcode*.app` (preferring the canonical `Xcode.app`) whose `Contents/Developer` does have it.

---

## [0.1.6] - 2026-05-03

### Added
- **Browser-side recording.** Record button in the single-device sidebar (`/simulators/<udid>`) and the device-farm focus pane (`/farm`) captures the live view to a downloadable WebM/MP4. The recording reuses what's already on the page — bezel `<img>`, decoded canvas, PinchOverlay's existing dot positions — and composites them into a recording-only canvas while active; idle cost is zero. Chrome / Safari preference for MP4 (H.264), WebM (VP9 / VP8) fallback. Exposed as `BrowserRecorder` in `Resources/Web/recorder.js`. See [`docs/features/recording.md`](docs/features/recording.md).
- **Auto-bump live stream quality during recording.** When Record is pressed on `/simulators/<udid>`, the stream is reconfigured to scale=1, 60 fps, 8 Mbps so the source canvas is at native resolution before drawImage scales into the composite — restored to the user's previous preset on Stop.

### Changed
- **MediaRecorder defaults tuned for visible quality** — `videoBitsPerSecond: 12_000_000` and `imageSmoothingQuality: 'high'` on the compose canvas, both overridable per `BrowserRecorder` instance.
- 
---

## [0.1.5] - 2026-05-03

### Changed
- Bug fixes and improvements.

---

## [0.1.4] - 2026-05-03

### Added
- **Device farm — interactive multi-device control surface served by `baguette serve`.** A standalone web UI that streams every booted simulator side-by-side, with filtering, sorting, wall / list view modes, and live telemetry per tile. Pieces:
  - **Bezel display mode** with `DeviceFrame` integration; falls back to **9-slice bezel composition** when a device has no packaged frame asset. Chrome buttons can layer above the viewport via `onTop` z-order.
  - **Input round-trips through the existing pipeline** — `SimInputBridge` wires the farm UI's gestures, hardware buttons, and pinch overlay into `GestureDispatcher` → `IndigoHIDInput`, so anything the CLI can drive, the farm UI can drive.
  - **Focused tile mirroring** is a canvas copy — the focus pane re-parents the source canvas directly rather than spinning up a separate `<video>` element.

### Changed
- **Farm grid rendering optimized** — selection updates use delta diffs instead of full re-mounting; element mounting and bezel rendering reworked for fewer DOM writes per frame; wall view layout unified and flexbox-centered.

### Fixed
- **Wrapper sizing now matches bezel image dimensions** so device frames align in the farm grid.
- **Element rendering in raw (no-bezel) mode** correctly handles toggling display modes.
- **`ReconfigParser` number parsing** simplified to handle numeric casting consistently.

---

[Unreleased]: https://github.com/tddworks/baguette/compare/v0.1.68...HEAD
[0.1.68]: https://github.com/tddworks/baguette/compare/v0.1.67...v0.1.68
[0.1.67]: https://github.com/tddworks/baguette/compare/v0.1.66...v0.1.67
[0.1.66]: https://github.com/tddworks/baguette/compare/v0.1.65...v0.1.66
[0.1.65]: https://github.com/tddworks/baguette/compare/v0.1.64...v0.1.65
[0.1.64]: https://github.com/tddworks/baguette/compare/v0.1.63...v0.1.64
[0.1.63]: https://github.com/tddworks/baguette/compare/v0.1.62...v0.1.63
[0.1.62]: https://github.com/tddworks/baguette/compare/v0.1.61...v0.1.62
[0.1.61]: https://github.com/tddworks/baguette/compare/v0.1.6...v0.1.61
[0.1.6]: https://github.com/tddworks/baguette/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/tddworks/baguette/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/tddworks/baguette/compare/v0.1.1...v0.1.4
