import Foundation

/// A parsed iOS runtime version — the comparable key serve uses to
/// pick the *latest* runtime when it auto-provisions a simulator.
///
/// CoreSimulator surfaces runtimes both as display names (`"iOS 26.5"`)
/// and as identifiers (`"com.apple.CoreSimulator.SimRuntime.iOS-26-5"`),
/// so `init(parsing:)` accepts either shape. Comparison is numeric on
/// `(major, minor)` — lexicographic sort would rank `"iOS 9.0"` above
/// `"iOS 26.5"` and create a sim on a stale runtime.
struct RuntimeVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int

    init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// Pull the first `<major>.<minor>` (or bare `<major>`) out of the
    /// text, treating `-` and `.` as equivalent separators so the
    /// identifier form (`…iOS-26-5`) parses the same as the display
    /// name (`iOS 26.5`). Returns `nil` when no leading-digit number is
    /// present.
    init?(parsing text: String) {
        // Collect every maximal run of digits as an integer; any
        // non-digit (space, `.`, `-`, letters) ends a run. The first
        // two runs are major.minor — `iOS 26.5`, `iOS-26-5`, and
        // `…SimRuntime.iOS-26-5` all reduce to [26, 5].
        var numbers: [Int] = []
        var current = ""
        for ch in text {
            if ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                numbers.append(Int(current) ?? 0)
                current = ""
            }
        }
        if !current.isEmpty { numbers.append(Int(current) ?? 0) }

        guard let first = numbers.first else { return nil }
        self.major = first
        self.minor = numbers.count > 1 ? numbers[1] : 0
    }

    static func < (lhs: RuntimeVersion, rhs: RuntimeVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    /// Return the original string whose parsed version is newest, or
    /// `nil` when none of the inputs parse. Unparseable entries are
    /// skipped rather than failing the whole selection.
    static func latest(of texts: [String]) -> String? {
        texts
            .compactMap { text -> (String, RuntimeVersion)? in
                RuntimeVersion(parsing: text).map { (text, $0) }
            }
            .max { $0.1 < $1.1 }?
            .0
    }
}
