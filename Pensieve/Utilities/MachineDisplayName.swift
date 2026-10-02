import Foundation
import SystemConfiguration

enum MachineDisplayName {
    static let defaultsKey = "machineDisplayName"

    static func currentHostName() -> String? {
        SCDynamicStoreCopyComputerName(nil, nil) as String?
    }

    static func publishedFallback(hostName: String?) -> String {
        guard let name = hostName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return "Mac" }
        return name
    }

    static func seedIfNeeded(defaults: UserDefaults, hostName: () -> String?) {
        guard defaults.object(forKey: defaultsKey) == nil else { return }
        guard let name = hostName()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return }
        defaults.set(name, forKey: defaultsKey)
    }
}
