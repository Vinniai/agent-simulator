import ArgumentParser
import Foundation

/// `agent-simulator delete --udid <id> [--device-set …]`
///
/// Destroys a simulator device — the counterpart to `shutdown` (which
/// only stops a running device). Used to clean up the throwaway
/// "agent-simulator" device that `serve --auto-boot` provisions.
struct DeleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a simulator device"
    )

    @OptionGroup var options: DeviceOption

    func run() {
        let simulators = CoreSimulators(deviceSetPath: options.deviceSet)
        guard let simulator = simulators.find(udid: options.udid) else {
            log("Device \(options.udid) not found")
            Foundation.exit(1)
        }
        let name = simulator.name
        do {
            try simulators.deleteSimulator(udid: options.udid)
            log("Deleted \(name)")
        } catch {
            log("Delete failed: \(error)")
            Foundation.exit(1)
        }
    }
}
