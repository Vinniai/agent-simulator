import Foundation

/// What `agent-simulator serve` should do at startup to guarantee the web
/// picker has a booted simulator to attach to.
///
/// A pure decision over the current fleet — the side effects (boot an
/// existing device, create a new one) are the App layer's job, kept out
/// of here so the policy stays unit-testable without CoreSimulator. The
/// goal is turnkey: run `serve` on an idle host and a simulator comes up
/// on its own, while a host that already has one up is never disturbed.
enum SimulatorStartupPlan: Equatable, Sendable {
    /// A simulator is already booted (or booting) — leave the fleet
    /// alone; the picker has something to show.
    case useRunning

    /// Nothing is coming up, but a simulator with the auto-boot name
    /// already exists in the set — boot it rather than spawning a
    /// duplicate every launch.
    case bootExisting(udid: String)

    /// Nothing is coming up and no auto-boot simulator exists — create
    /// one (on the latest available runtime) and boot it.
    case createAndBoot(name: String)

    /// Decide from a fleet snapshot. `desiredName` is the auto-boot
    /// simulator's name (`"agent-simulator"`); the match is case-insensitive
    /// so a hand-created `Agent-Sim` still gets reused.
    static func decide(all: [any Simulator], desiredName: String) -> SimulatorStartupPlan {
        if all.contains(where: { $0.state == .booted || $0.state == .booting }) {
            return .useRunning
        }
        if let existing = all.first(where: {
            $0.name.caseInsensitiveCompare(desiredName) == .orderedSame
        }) {
            return .bootExisting(udid: existing.udid)
        }
        return .createAndBoot(name: desiredName)
    }
}
