import Foundation

/// Dogfood mode: the app was launched by `script/dogfood.sh` against a throwaway home, fenced by
/// `sandbox-exec`. The fence stops filesystem writes
/// outside the fake home; this flag covers the two out-of-process sinks it cannot see — launchd
/// (the legacy-agent migration) and Sparkle — so a dogfood run never talks to either.
enum DogfoodMode {
    static let environmentKey = "PENSIEVE_DOGFOOD"

    /// Resolved once per process from the launch environment.
    static let isActive: Bool = isActive(in: ProcessInfo.processInfo.environment)

    /// Pure form for tests: active only when the variable is exactly "1".
    static func isActive(in environment: [String: String]) -> Bool {
        environment[environmentKey] == "1"
    }
}
