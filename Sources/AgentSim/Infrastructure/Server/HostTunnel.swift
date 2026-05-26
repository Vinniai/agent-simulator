import Foundation

/// Runs a `Tunnel` and surfaces the public URL it advertises.
///
/// Mirrors `SimDeviceLogStream`: owns the state machine (started /
/// stopped, one-shot URL discovery, byte-to-line buffering, exit
/// mapping) and delegates the OS-level spawn to a `Subprocess`
/// collaborator. The `Subprocess` is the only piece that touches
/// `Foundation.Process` / `Pipe` / `kill(pid)`; `HostTunnel` itself
/// is pure logic, unit-covered via `MockSubprocess`.
///
/// The provider CLI (`cloudflared` / `ngrok`) is resolved against
/// `PATH` by launching through `/usr/bin/env` — the tools install
/// wherever Homebrew / the user put them, and we don't want to hard-
/// code a prefix.
final class HostTunnel: @unchecked Sendable {
    private let tunnel: Tunnel
    private let subprocess: any Subprocess

    private let lock = NSLock()
    private var lineBuffer = LineBuffer()
    private var started = false
    private var stopped = false
    private var foundURL = false
    private var onURLCb:  (@Sendable (URL) -> Void)?
    private var onExitCb: (@Sendable (Error?) -> Void)?

    /// Production callers default to `HostSubprocess()`; tests inject
    /// `MockSubprocess` to drive the state machine deterministically.
    init(tunnel: Tunnel, subprocess: any Subprocess = HostSubprocess()) {
        self.tunnel = tunnel
        self.subprocess = subprocess
    }

    /// Launch the tunnel. `onURL` fires once, with the first public
    /// URL parsed out of the child's output. `onExit` fires once if
    /// the child winds down on its own (nil for a clean exit, a
    /// `TunnelError.nonZeroExit` otherwise) — an operator-initiated
    /// `stop()` does *not* fire it.
    func start(
        onURL: @escaping @Sendable (URL) -> Void,
        onExit: @escaping @Sendable (Error?) -> Void
    ) throws {
        lock.lock()
        if started {
            lock.unlock()
            throw TunnelError.alreadyStarted
        }
        self.onURLCb = onURL
        self.onExitCb = onExit
        self.started = true
        lock.unlock()

        // env resolves the provider binary on PATH; argv is the bare
        // executable name followed by the provider's own arguments.
        let argv = [tunnel.executable] + tunnel.arguments
        do {
            try subprocess.run(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: argv,
                onBytes: { [weak self] bytes in self?.consume(bytes) },
                onExit:  { [weak self] code  in self?.handleExit(code) }
            )
        } catch {
            lock.lock()
            self.onURLCb = nil
            self.onExitCb = nil
            self.started = false
            lock.unlock()
            throw TunnelError.launchFailed(reason: error.localizedDescription)
        }
        log("[tunnel] \(tunnel.provider.rawValue) launching for 127.0.0.1:\(tunnel.localPort)")
    }

    func stop() {
        lock.lock()
        guard started, !stopped else { lock.unlock(); return }
        stopped = true
        onURLCb = nil
        onExitCb = nil
        lock.unlock()

        subprocess.terminate()
    }

    // MARK: - private

    private func consume(_ bytes: Data) {
        lock.lock()
        guard !stopped, !foundURL, let cb = onURLCb else {
            lock.unlock()
            return
        }
        let lines = lineBuffer.append(bytes)
        var hit: URL?
        for line in lines {
            if let url = tunnel.publicURL(in: line) {
                hit = url
                break
            }
        }
        if hit != nil { foundURL = true }
        lock.unlock()
        if let hit { cb(hit) }
    }

    private func handleExit(_ status: Int32) {
        lock.lock()
        // `stop()` flips `stopped` first, so a follow-up onExit from
        // the SIGTERM'd child has nothing left to report. Drop it.
        if stopped { lock.unlock(); return }
        stopped = true
        let cb = onExitCb
        onURLCb = nil
        onExitCb = nil
        lock.unlock()

        if status == 0 {
            cb?(nil)
        } else {
            cb?(TunnelError.nonZeroExit(code: status))
        }
    }
}
