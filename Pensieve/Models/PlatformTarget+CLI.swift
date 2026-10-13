import Foundation

extension PlatformTarget {
    var cliID: String {
        switch self {
        case .claudeCode: "claude"
        case .openClaw: "openclaw"
        default: rawValue
        }
    }

    static func cliID(for stored: String) -> String { PlatformTarget(rawValue: stored)?.cliID ?? stored }
}
