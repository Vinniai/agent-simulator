# Chrome bezel rendering

`baguette serve` renders each simulator with a real-looking device
bezel — the rounded body silhouette, the rail, the side buttons —
using Apple's own DeviceKit chrome bundles as source. Two outputs:

- **Merged composite** (`/simulators/<UDID>/bezel.png`) — the device
  body with hardware buttons baked into a single PNG. Used by the
  flat (non-actionable) view.
- **Bare composite** (`/simulators/<UDID>/bezel.png?buttons=false`) —
  the body without overlaid buttons; the front-end positions each
  button as its own animatable `<img>` over it. Used by the
  actionable view (focus-mode toolbar's bezel toggle).

Both share one positioning rule — described below — so the actionable
overlay tracks the merged composite pixel-for-pixel.

## Source data

Each chrome bundle lives at
`/Library/Developer/DeviceKit/Chrome/<id>.devicechrome/Contents/Resources/`
and ships:

- `chrome.json` — the layout schema (`images.sizing`, `images.devicePadding`,
  `paths.simpleOutsideBorder`, `inputs[].offsets`, etc.).
- A composite PDF (`PhoneComposite.pdf`, `WatchComposite.pdf`, …) and
  a 9-slice (`topLeft.pdf` / `top.pdf` / …) for chromes that ship
  only the corner pieces.
- One PDF per hardware input — `DigitalCrown.pdf`, `SideButton.pdf`,
  `Mute BTN.pdf`, `X_Power BTN.pdf`, plus their `... Dn.pdf` pressed
  variants.

Mapping from simulator name to chrome bundle goes through
`profile.plist`'s `chromeIdentifier` key — see
`Sources/Baguette/Infrastructure/Chrome/FileSystemChromeStore.swift`.

## Geometry pipeline

```
chrome.json + .pdf assets
       │
       ▼  DeviceChrome.parsing(json:)
DeviceChrome { screenInsets, outerCornerRadius, devicePadding,
               buttons: [ChromeButton(normalOffset, rolloverOffset, …)] }
       │
       ▼  LiveChromes.loadComposite     (CGPDFDocument → CGImage)
ChromeImage (the bare body, e.g. 296 × 313 for watch4)
       │
       ▼  LiveChromes.assemble
DeviceChromeAssets {
    composite     = merged-bezel PNG    (canvas = composite + devicePadding)
    bareComposite = body-only PNG       (the rasterized chrome PDF as-is)
    buttonImages  = per-name rasterized button PNGs (for the overlay)
    buttonMargins = chrome.devicePadding (authoritative, NOT inferred)
}
```

Two layers feed the merged composite: every `onTop: false` button is
drawn BEHIND the composite (the cap pokes through a transparent slot
in the bezel rail — iPhone power/volume/action), every `onTop: true`
button is drawn ON TOP (Apple Watch's orange action button doesn't
appear in the watch composite at all). The actionable overlay
respects the same flag for z-index (z=0 behind the bezel `<img>`, z=2
in front).

## chrome.json button offsets — the asymmetric rule

Every `inputs[]` entry carries two offsets:

```json
{ "name": "side-button",
  "anchor": "right",
  "image": "SideButton",
  "imageDown": "SideButton Dn",
  "onTop": false,
  "offsets": {
    "normal":   { "x": -30, "y": 160 },
    "rollover": { "x": -25, "y": 160 }
  } }
```

The interpretation differs per anchor — verified by reading
SimulatorKit (`SimDisplayChromeView.ChromeInput.normalRect` /
`.rolloverRect`, plus the `centerXAnchor` / `centerYAnchor` /
`constraintEqualToAnchor:constant:` selrefs in
`/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks/SimulatorKit.framework/Versions/A/SimulatorKit`)
and by side-by-side comparison against the real `Simulator.app`
window:

| anchor          | `offset.x` means                                  | `offset.y` means          |
|-----------------|----------------------------------------------------|----------------------------|
| left            | image **CENTRE** on the anchored axis              | image **TOP** edge         |
| top             | image **CENTRE** on the anchored axis              | image **TOP** edge         |
| bottom          | image **CENTRE** on the anchored axis              | image **TOP** edge         |
| right           | image **LEFT (inner) edge**, measured outward from `composite.width` | image **TOP** edge |

Why y is **TOP**, not **CENTRE**: tall caps (watch4 crown 67 px,
iPhone power 117 px) and short caps (Mute BTN 32 px) with the same
`offset.y` are supposed to start at the same y. Treating y as centre
drifts taller caps downward by `imgH / 2` — visible as the action
button floating below where Apple draws it (Image #8 regression in
the development history).

Why x is **INNER EDGE** for right-anchor specifically: watch4 ships
DigitalCrown (25 wide) and SideButton (36 wide) with offsets that,
under a CENTRE interpretation, land the entire image inside the body
silhouette. The overlay sits behind the bezel image's baked
crown/side silhouette and is invisible at rest — no cap-past-rail
protrusion (Image #14 regression). Inner-edge keeps both crown and
side-button visible past the rail with the cap-pop the chrome.json
offsets specify.

### At-rest position for right-anchor: `2N − R`

chrome.json's `normalOffset` is the **hover** position — the cap
already popped past the rail — not the relaxed at-rest position.
At-rest mirrors the rollover delta INWARD:

```
restX = 2 * normalOffset.x - rolloverOffset.x
```

For watch4's side-button (`normal=-30`, `rollover=-25`) that gives
`restX = -35` → image right edge at `composite.width + 1`, a 1 px
protrusion. Hover translates outward by `rollover − normal = +5`
chrome-px, landing the cap at `normalOffset.x = -30` → image right
at `composite.width + 6` (6 px protrusion), matching Apple's hovered
side-button. For caps without a hover animation (DigitalCrown ships
`normal == rollover = -23`) the formula collapses to `normalOffset.x`
and the cap stays fixed at 2 px protrusion.

### `buttonTopLeft` (Swift) and `_size` (JS) summary

| anchor | Swift `buttonTopLeft` → top-left point | JS `_size` → CSS `left`/`top` |
|---|---|---|
| left   | `(compX + offset.x - imgW/2, compY + offset.y)` | `cxPct − halfWPct%`, `tyPct%` |
| right  | `(compX + compW + (2N.x − R.x), compY + (2N.y − R.y))` | `(bareW + 2N.x − R.x) / bareW %`, `(2N.y − R.y) / bareH %` |
| top    | `(baseX + offset.x − imgW/2, compY + offset.y)` | `cxPct − halfWPct%`, `tyPct%` |
| bottom | `(baseX + offset.x − imgW/2, compY + compH + offset.y)` | `cxPct − halfWPct%`, `(bareH + offset.y) / bareH %` |

`compX = buttonMargins.left`, `compY = buttonMargins.top` (the canvas
margins added around the rasterized composite — see below).

## Canvas margins — `images.devicePadding`

Apple ships an `images.devicePadding` block on every chrome,
describing the canvas space reserved around the composite for button
overshoot and rollover-animation slack:

| chrome     | devicePadding                  |
|------------|--------------------------------|
| phone11    | `top:0, left:9, bottom:0, right:9`   |
| phone13    | `top:0, left:9, bottom:0, right:9`   |
| watch4     | `top:0, left:0, bottom:0, right:11`  |
| tablet5    | `top:9, left:0, bottom:0, right:10`  |

`LiveChromes.assemble` reads these verbatim into
`DeviceChromeAssets.buttonMargins` — the merged canvas is
`composite.size` plus `devicePadding` on each side. We do not infer
margins from button geometry (the prior `imgW ± offX` formula
coincidentally matched watch4's `right: 11` because the side-button
math worked out to 11, but produced wrong values for chromes whose
button geometry didn't line up — tablet5 has `top: 9` despite
shipping no buttons at all). The screen rect inside `layoutJSON` is
shifted by `(devicePadding.left, devicePadding.top)` so it lands on
the real screen cutout in the merged image.

## Hover animation (actionable mode)

`bezel-buttons.js` drives a three-state animation off chrome.json's
two offsets:

- **At rest** — position via `2N − R` (right anchor) or `rolloverOffset`
  (others). For onTop:false caps the overlay sits behind the bezel
  `<img>` (z=0) and only the cap-past-bezel portion is visible. For
  onTop:true caps (watch4 action) the overlay sits in front (z=2).
- **Hover** (`mouseenter`) — CSS transform translates outward by the
  chrome.json `rollover − normal` delta. For right-anchor that lands
  the cap at `normalOffset.x` — the "popped out" hover state.
- **Press** (`mousedown`) — translates by `−delta` (inward of at-rest)
  and swaps the sprite to `imageDown.pdf`'s rasterized variant. On
  `mouseup`/`mouseleave` the cap snaps back to rest with the
  `imageDown` swap reverting to the at-rest sprite.

The press fires `onPress(name, durationSeconds)`. `name` is the wire
button (`'home'`, `'power'`, `'action'`, `'digital-crown'`,
`'side-button'`, `'left-side-button'`, …); `durationSeconds` is the
real mousedown→mouseup hold time — the Swift dispatch routes it
through `IndigoHIDMessageForHIDArbitrary` for buttons that need the
long-press semantics (e.g. Apple Watch action button's "Hold for
Ring", iPhone power's Siri / SOS).

## Adding a new chrome / button family

1. Confirm the simulator name maps to a chrome ID via its
   `profile.plist` (`chromeIdentifier`). Apple ships everything we
   need at `/Library/Developer/DeviceKit/Chrome/<id>.devicechrome/`.
2. If the new button has a wire-distinct HID code, add it to
   `DeviceButton` (`Sources/Baguette/Domain/Common/CoordinateTypes.swift`)
   with the (page, usage) pair from chrome.json's `usagePage` /
   `usage` fields and a wire name matching chrome.json's `name`.
3. Extend `Press.allowed` (`Sources/Baguette/Domain/Input/Press.swift`)
   so the gesture registry accepts the new wire name. Add the same
   name to `WIRE_BUTTON` in
   `Sources/Baguette/Resources/Web/bezel-buttons.js` so the actionable
   overlay routes clicks through `simInput.button(...)`.
4. The geometry path is data-driven — no code change needed for
   new chrome bundles unless their `inputs[]` carries a previously
   unseen `anchor` or `align` value.

## Verifying changes

```bash
# Restart baguette serve so the new binary + JS land.
make && pkill -f baguette/serve; ./Baguette serve &

# Pull the merged composite (with buttons baked) for the device:
curl -s "http://127.0.0.1:8421/simulators/<UDID>/bezel.png" \
  -o /tmp/merged.png && sips -g pixelWidth -g pixelHeight /tmp/merged.png

# Pull the bare composite (no buttons baked — what the actionable
# overlay sits on top of):
curl -s "http://127.0.0.1:8421/simulators/<UDID>/bezel.png?buttons=false" \
  -o /tmp/bare.png && sips -g pixelWidth -g pixelHeight /tmp/bare.png

# Inspect the layout JSON the front-end consumes:
curl -s "http://127.0.0.1:8421/simulators/<UDID>/chrome.json" | jq
```

Open `http://127.0.0.1:8421/simulators/<UDID>` (focus mode), flip the
top-toolbar bezel toggle (third icon from the right) to switch
between flat and actionable views, and hover the right-rail buttons —
the cap should slide outward by the chrome.json `rollover − normal`
delta on hover and snap inward on mousedown.
