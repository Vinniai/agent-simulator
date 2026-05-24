# Camera

Pipe a Mac webcam (FaceTime HD, USB, Continuity Camera) into an iOS
app's `AVCaptureVideoPreviewLayer`, `AVCapturePhotoOutput`, and
`UIImagePickerController` running inside the simulator. The app sees
the chosen Mac camera as if it were a real iOS camera — barcode
scanners scan, profile-photo uploads work, viewfinders fill — without
opening Xcode, without installing a separate menu-bar app.

Two halves cooperate:

- **Mac side** (this repo, Swift): a `CameraSession` orchestrator
  driven from the browser's camera panel. Reads BGRA frames off an
  `AVCaptureSession` and writes them into a fixed-size mmap'd file
  (`/tmp/SimCam.bgra`).
- **iOS-Simulator side** (`VirtualCamera/`, vendored from
  `asc-pro/SimCam`): a small ObjC dylib that hooks AVFoundation /
  UIImagePickerController inside every simulator-launched app and
  substitutes the shared-buffer frame for the (non-existent)
  hardware camera. Loaded via `DYLD_INSERT_LIBRARIES`.

The browser is the picker; baguette is the producer; the dylib is the
consumer. No CLI verb in v1 — the surface is the browser's camera
control card.

## Entry points

- Browser camera card on `/simulators/<UDID>` (sidebar view, under
  the Camera disclosure). One device dropdown, Start/Stop, Fit/Fill,
  Mirror, live FPS.
- Wire JSON over the `/simulators/:udid/camera` WebSocket — agents
  can drive the same flow programmatically.

## Wire JSON

The browser opens `ws://<host>:<port>/simulators/<udid>/camera` and
exchanges text frames.

**Browser → server:**

```json
{ "type": "camera_list" }
{ "type": "camera_start",
  "deviceUID": "0x14600000046d0825",
  "fit": "fit",                // "fit" | "fill"
  "mirror": false }
{ "type": "camera_stop" }
{ "type": "camera_set_flags",
  "fit": "fill",
  "mirror": true }
```

**Server → browser:**

```json
{ "type": "camera_devices",
  "devices": [
    { "uid": "0x14600000046d0825",
      "name": "FaceTime HD Camera",
      "isDefault": true }
  ]
}
{ "type": "camera_state",
  "ok": true,
  "phase": "streaming",        // "idle" | "streaming"
  "fps": 29.97,
  "device": "0x14600000046d0825" }
{ "type": "camera_state",
  "ok": false,
  "phase": "idle",
  "fps": 0,
  "error": "Camera access denied. Open System Settings → Privacy → Camera and enable baguette." }
```

`camera_devices` lands once on connect and again after every
`camera_list`. `camera_state` lands after every `camera_start` /
`camera_stop` / `camera_set_flags`.

## Pipeline

```
   Browser              Server (baguette)                         iOS Simulator
┌────────────┐  WS    ┌────────────────────────┐               ┌──────────────────┐
│ sim-camera │◀─────▶│ /simulators/:udid/camera │               │ AVCaptureVideo   │
│ .js (card) │  JSON  │  CameraSession (state) │               │ PreviewLayer .   │
└────────────┘        │   ├─ AVCameraCapture   │               │  setSession:     │
                      │   │   (BGRAConverter)  │               │  hook  ▲         │
                      │   ├─ SharedMemoryFrame │               │        │         │
                      │   │   Sink (mmap)     ─┼───────────────┼──▶ /tmp/SimCam   │
                      │   │                    │  24-byte hdr  │   .bgra (read)   │
                      │   └─ SimctlSimulator   │  + BGRA       │        │         │
                      │       Injection ──────▶│  launchctl    │  VirtualCamera   │
                      └────────────────────────┘  setenv       │    .dylib        │
                                                  DYLD_INSERT  │  (DisplayLink)   │
                                                  _LIBRARIES   └──────────────────┘
```

### Mac side (this repo)

- `Domain/Camera/` — pure value types and `@Mockable` collaborators:
  - `CameraDevice` — `{uid, name, isDefault}`, structurally equal.
  - `CameraFrame` — BGRA bytes + dims + sequence + timestamp,
    validated on construction (rejects oversized frames or
    mismatched pixel data length).
  - `CameraFlags` — `{fillGravity, mirror}`. `.packed() -> UInt32`
    matches the dylib's `kSimCamFlag*` bit layout.
  - `SharedFrameLayout` — header offsets + canvas cap (1280×1280).
    Static `encodeHeader(...) -> [UInt8]` is little-endian and
    byte-for-byte tested.
  - `BGRAConverter` — pure factory that strips row-padding from a
    `CVPixelBuffer` base address into a tightly packed `CameraFrame`.
  - `CameraSession` — `@MainActor` orchestrator. Drives three
    collaborators (`CameraCapture`, `CameraFrameSink`,
    `SimulatorInjection`). State: `.idle | .streaming(deviceUID:)`.
  - `CameraMessage` — pure parser for the inbound WS envelope.
- `Infrastructure/Camera/`:
  - `AVCameras` — one-shot enumeration via
    `AVCaptureDevice.DiscoverySession`.
  - `AVCameraCapture` — `CameraCapture` orchestrator that converts
    raw BGRA frames into `CameraFrame`s with monotonic sequence
    numbers; depends on a `VideoCapture` collaborator. Unit-tested.
  - `HostVideoCapture` — thin (~80 LOC) `AVCaptureSession` wrapper.
    Integration-only.
  - `SharedMemoryFrameSink` — mmap-backed writer; rewrites the
    24-byte header + pixels and `msync(MS_SYNC)`s on every frame.
  - `SimctlSimulatorInjection` — runs `xcrun simctl spawn <udid>
    launchctl setenv DYLD_INSERT_LIBRARIES <dylibPath>`. Uses the
    existing `Subprocess` collaborator → 100% unit-tested.
  - `VirtualCameraInstaller` — resolves the bundled
    `VirtualCamera.dylib` from `Bundle.module`, sha256-keys it, and
    copies into `~/Library/Application Support/Baguette/builds/<sha12>/`.

### iOS-Simulator side (`VirtualCamera/`)

Vendored under `VirtualCamera/`. Internal symbols retain the SimCam
prefix to keep upstream re-syncs diff-friendly; see
`VirtualCamera/VENDORED_FROM.md`. The dylib:

- Hooks `-[AVCaptureVideoPreviewLayer setSession:]` and attaches a
  `CADisplayLink` driver that pushes the latest BGRA frame from
  `/tmp/SimCam.bgra` into the layer's `contents`.
- Hooks `-[AVCapturePhotoOutput capturePhotoWithSettings:delegate:]`
  and synthesises a delegate sequence from the latest shared frame
  (still capture works without a real camera).
- Hooks `+[UIImagePickerController isSourceTypeAvailable:]` to
  report `.camera` as available; walks the picker's view tree on
  `viewDidAppear:` and intercepts the disabled-shutter delegate so
  the simulator's picker actually delivers a photo on tap.

## Dylib installation flow

1. `build.sh` runs `VirtualCamera/build.sh` first → produces
   `VirtualCamera/VirtualCamera.dylib` (fat: arm64 + x86_64,
   linker-signed adhoc, install-name `@rpath/VirtualCamera.dylib`).
2. The artifact is copied into
   `Sources/Baguette/Resources/VirtualCamera/VirtualCamera.dylib` so
   SPM bundles it as a `.copy` resource.
3. First time `camera_start` lands on the WS,
   `VirtualCameraInstaller.installIfNeeded()` reads the bundled
   bytes, computes `sha256(bytes).prefix(12)`, and copies into
   `~/Library/Application Support/Baguette/builds/<sha12>/VirtualCamera.dylib`.
   Idempotent — if the file already exists at that path we trust
   its contents (the path itself is sha-keyed).
4. `SimctlSimulatorInjection.arm(...)` runs
   `xcrun simctl spawn <udid> launchctl setenv DYLD_INSERT_LIBRARIES <path>`.
   The env var survives until the simulator reboots; apps launched
   after the arming load the dylib via dyld.
5. Frames pump through `/tmp/SimCam.bgra`; the dylib's display-link
   driver picks them up on the next tick.

## iOS-26 gotchas worth preserving

- **Per-hash install dir.** iOS 26's simulator dyld page-hash cache
  rejects a *replaced* dylib at the same path with
  `code:codesigning(3) invalid-page(2)`. Every release ships a
  different sha and lands at a different path, dodging the cache.
- **Linker adhoc sign only.** The `clang -Wl,-adhoc_codesign`
  flag in `VirtualCamera/build.sh` sets the `linker-signed` flag the
  simulator's dyld accepts. A post-build `codesign --force --sign -`
  strips that flag and the dylib stops loading.
- **`setSourceType: .camera` throws without the hook.** Without
  swizzling `+isSourceTypeAvailable:`,
  `UIImagePickerController().sourceType = .camera` raises
  `NSInvalidArgumentException('Source type 1 not available')` in the
  simulator. The hook lies and returns `YES` for `.camera`.
- **Apps launched *before* arming don't load the dylib.** dyld
  honours `DYLD_INSERT_LIBRARIES` only at exec time. After arming, a
  fresh launch (or terminate + relaunch) picks the dylib up.
  Baguette doesn't reopen apps for the user; the camera card surfaces
  this when the captured frame doesn't appear in the live preview.

## Adding a new camera source

The current adapter pulls from `AVCaptureSession` (Mac webcams). To
add a different source — e.g. a posted image stream from an agent,
or `getUserMedia` from the browser:

1. New `CameraCapture` implementation in `Infrastructure/Camera/`.
   Same role-noun for the collaborator it depends on (e.g.
   `BrowserFrameStream`) if it's conversational; or a one-shot
   adapter if the API gives back a stream you can pump directly.
2. Add a new WS message type (e.g. `camera_frame_data`) in
   `CameraMessage` with a parser test.
3. Wire the dispatch into `Server.cameraWS` — switch on the new
   case and call into the appropriate session method.

`SharedMemoryFrameSink` and `SimulatorInjection` stay the same —
they don't care where the bytes came from.

## Known limits (v1)

- **One camera at a time per host.** All simulators write
  `/tmp/SimCam.bgra`; the dylib reads whichever bytes landed last.
  The Server's camera WS doesn't reject a second concurrent start
  in v1 — the second one just trashes the first one's frames. To
  scope per-sim we'd patch the dylib to accept a path override.
- **No CLI yet.** `baguette camera --udid … --device <UID>` would
  be a thin layer over the same WS handler; the wire path is
  already there for agents that need it.
- **No "apps needing reopen" diagnostic.** SimCamMac surfaces a list
  of running apps that started before the dylib was armed. Baguette
  defers that to a v2; users who don't see frames should
  terminate-and-relaunch the iOS app.
- **Mac-only producer.** A future browser `getUserMedia` source
  (sketched in the design phase) would let the page's webcam feed
  the iOS app without going through AVFoundation on the host.
