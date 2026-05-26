# Driving a simulator from elsewhere

The shape of the problem: the iOS simulator (and the private SimulatorKit /
CoreSimulator frameworks `agent-sim` drives) only exist on a Mac. But the
operator — you, or an agent like Claude running in a browser — is often
*somewhere else*. `agent-sim serve` runs on the Mac that owns the simulator;
everything else dials in.

This doc covers the three ways to reach a running `serve` from another
machine, and `agent-sim connect`, the CLI smoke test that proves the link.

```
┌─────────────── Mac mini at home ───────────────┐        ┌──────── elsewhere ────────┐
│  iPhone 17 Pro sim                              │        │  browser  → live UI       │
│      ▲ frames / ▼ HID                           │  WS    │  agent-sim connect        │
│  agent-sim serve  ──────────────────────────────────────│  → smoke test (frames+tap)│
│  (SimulatorKit + 9-arg Indigo HID)              │        │  Claude on the web        │
└─────────────────────────────────────────────────┘        └───────────────────────────┘
```

## 1. The serve startup hint

Whatever interface you bind, `serve` prints the exact `connect` line the
other end should run — it resolves the bind to a *dialable* address so you
never have to figure out the LAN IP by hand:

```bash
$ agent-sim serve --host 0.0.0.0
[agent-sim] remote: agent-sim connect http://192.168.1.132:8421 --udid 75091244-…
[agent-sim] listening on http://0.0.0.0:8421/simulators
```

- A `127.0.0.1` or `0.0.0.0` bind is not reachable off-box (loopback, and the
  wildcard "all interfaces" address, respectively), so the hint substitutes
  this Mac's **LAN IP**.
- A genuinely routable bind host is shown verbatim.
- With `--tunnel`, the hint reprints with the **public URL** once the tunnel
  comes up.

The `--udid` it suggests is the simulator `serve` auto-booted (or, with
`--no-auto-boot`, the one already running).

## 2. Three ways to reach it

### LAN — same network, no extra tooling

Bind a routable interface so off-box clients can connect (loopback only
accepts connections from the same machine):

```bash
# on the mini
agent-sim serve --host 0.0.0.0
```

The same-origin guard still holds: a first-party client (`agent-sim connect`,
or a browser opening the served page) carries a matching `Origin`/`Host`, so
it passes; a cross-site page does not. Dial it from any machine on the LAN
using the hint's URL.

### Tailscale / VPN — private mesh, loopback stays loopback

Keep the strict loopback bind and just allowlist the mesh hostname through the
DNS-rebind guard — nothing is exposed beyond your tailnet:

```bash
# on the mini
agent-sim serve --host 0.0.0.0 \
  --trusted-host mac.tailnet.ts.net \
  --trusted-host 100.101.102.103          # a 100.x tailnet IP works too
```

`--trusted-host` is repeatable. An allowlisted `Host` clears the rebind guard,
but **same-origin still holds** — a cross-site page served from the trusted
name cannot drive the simulator.

### Public tunnel — a temporary https URL

For reaching the sim from a network you don't control (e.g. Claude on the web),
expose the loopback bind over a quick tunnel. Requires the provider's CLI on
`PATH` (`cloudflared` or `ngrok`):

```bash
# on the mini
agent-sim serve --tunnel cloudflare       # or: --tunnel ngrok
# [tunnel] public URL: https://something.trycloudflare.com
# [tunnel] remote: agent-sim connect https://something.trycloudflare.com --udid 75091244-…
```

The tunnel's public hostname is discovered at runtime and auto-allowlisted, so
the guard lets it through while same-origin continues to gate cross-site pages.
A TLS-terminating tunnel forwards a port-less `Host`; the host match alone
establishes same-origin in that case.

## 3. `agent-sim connect` — prove the link

`connect` is a **smoke test**, not a viewer. It dials the same WebSocket the
browser would, counts the binary frames arriving downstream over a window, and
— if you pass `--tap` — fires one gesture up the same socket. Run it on the
*other* machine, with the URL from the serve hint:

```bash
$ agent-sim connect http://192.168.1.132:8421 --udid 75091244-… --tap 200,400
[agent-sim] connecting to ws://192.168.1.132:8421/simulators/75091244-…/stream?format=avcc …
[agent-sim] sent tap 200,400
[agent-sim] frames=178 ~59.3fps 5049B/frame
[agent-sim] handshake ok — stream is live
```

| Flag        | Meaning                                                            |
|-------------|--------------------------------------------------------------------|
| `<url>`     | Base URL of the remote serve — the same one you'd open in a browser. The `ws(s)://…/stream` route is derived for you. |
| `--udid`    | Which remote simulator to stream.                                  |
| `--tap X,Y` | Fire one tap at device-point `X,Y` to prove the upstream channel.  |
| `--size WxH`| Device size the `--tap` coordinates are relative to (default `393x852`). |
| `--format`  | `avcc` (H.264, default) or `mjpeg`.                                |
| `--seconds` | Sampling window to count frames over (default `3`).                |

**Verdict:** `frames > 0` → exit `0` and `handshake ok — stream is live`. Zero
frames → exit `1` and `no frames received`. Over `https`/`wss` the same
command works unchanged — pass the tunnel URL instead of the LAN one.

A couple of practical notes:

- The client raises its WebSocket frame ceiling to 16 MiB: a single AVCC seed
  / H.264 keyframe is far larger than the 16 KiB default, which would otherwise
  be rejected as a protocol violation and counted as zero frames.
- On a static screen you still see ~60 fps: once a client is attached the
  encoder re-emits the last frame at the configured rate so the decoder
  pipeline never stalls on a stale frame.

## Security model in one paragraph

The default `127.0.0.1` bind plus a same-origin + DNS-rebind guard means an
out-of-the-box `serve` is reachable only from the same machine. Opening a
routable bind (`--host 0.0.0.0`) keeps same-origin; `--trusted-host` clears the
rebind guard for named mesh hosts without weakening same-origin; `--tunnel`
auto-allowlists its own discovered public name. In every case a cross-site page
cannot drive the simulator, and nothing is published beyond the interface /
mesh / tunnel you explicitly chose.
