import Foundation

/// The recipe for a simulator serve auto-creates when the host is idle:
/// a name plus the CoreSimulator runtime + device-type identifiers to
/// build it from.
///
/// `choose` is the pure decision — given the runtimes and device types
/// CoreSimulator advertises (lifted into plain tuples by the
/// Infrastructure adapter), pick the newest available iOS runtime and
/// the newest iPhone, so the streamed device looks current. The
/// irreducible `createDeviceWithType:runtime:name:error:` call stays in
/// `CoreSimulators` and consumes the identifiers chosen here.
struct NewSimulatorSpec: Equatable, Sendable {
    let name: String
    let runtimeIdentifier: String
    let deviceTypeIdentifier: String

    /// Pick the simulator to create, or `nil` when the host advertises
    /// no usable iOS runtime or no iPhone device type (serve then just
    /// runs without auto-provisioning — the picker still lists whatever
    /// devices exist).
    static func choose(
        name: String,
        runtimes: [(name: String, identifier: String, available: Bool)],
        deviceTypes: [(name: String, identifier: String)]
    ) -> NewSimulatorSpec? {
        // Newest available iOS runtime. `RuntimeVersion.latest` works on
        // the display names; we map the winning name back to its
        // identifier.
        let iosRuntimes = runtimes.filter {
            $0.available && $0.name.localizedCaseInsensitiveContains("iOS")
        }
        guard let latestName = RuntimeVersion.latest(of: iosRuntimes.map(\.name)),
              let runtime = iosRuntimes.first(where: { $0.name == latestName })
        else { return nil }

        // Newest iPhone: highest model number, and at a tie prefer the
        // base model (shortest name beats "Pro" / "Pro Max").
        let iPhones = deviceTypes.filter { $0.name.hasPrefix("iPhone") }
        guard let deviceType = iPhones.max(by: { lhs, rhs in
            let l = modelNumber(lhs.name), r = modelNumber(rhs.name)
            if l != r { return l < r }
            return lhs.name.count > rhs.name.count
        }) else { return nil }

        return NewSimulatorSpec(
            name: name,
            runtimeIdentifier: runtime.identifier,
            deviceTypeIdentifier: deviceType.identifier
        )
    }

    /// The largest integer token in a device-type name — `"iPhone 17
    /// Pro"` → 17, `"iPhone SE (3rd generation)"` → 3, `"iPhone Air"` →
    /// 0. Numbered models thus outrank number-less ones.
    private static func modelNumber(_ name: String) -> Int {
        name
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap(Int.init)
            .max() ?? 0
    }
}
