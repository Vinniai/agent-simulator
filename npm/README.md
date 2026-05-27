# agent-simulator

Agent-driven **iOS Simulator** control from one CLI — boot/shutdown devices,
stream the screen, inject taps / swipes / pinches / keyboard input, dump the
accessibility tree, tail the unified log, and run a self-building review loop.
No Simulator.app GUI required.

```bash
npm install -g agent-simulator
agent-simulator list
agent-simulator serve            # web UI on http://localhost:8421/simulators
```

## Platform requirements

agent-simulator is a Swift binary that links private SimulatorKit / CoreSimulator
frameworks shipped with Xcode. It runs **only** on:

- **macOS on Apple Silicon** (`darwin` / `arm64`)
- **Xcode 26** installed, with `xcode-select` pointing at it

`npm install` is platform-gated (`os`/`cpu`), and the `postinstall` step
downloads the matching native binary from the
[GitHub release](https://github.com/Vinniai/agent-simulator/releases). Installs on
other platforms are skipped with a warning rather than failing.

## Other install paths

Build from source — see the
[project README](https://github.com/Vinniai/agent-simulator#readme) for the full CLI
reference, wire protocol, and architecture docs.

## License

Apache-2.0
