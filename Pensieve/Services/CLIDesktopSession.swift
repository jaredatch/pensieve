import Foundation
import Darwin
import SystemConfiguration

protocol CLIDesktopSessionReading {
    func hasGraphicAccess() throws -> Bool
}

struct CLIDesktopSession: CLIDesktopSessionReading {
    func hasGraphicAccess() throws -> Bool {
        // SSH and SSH-born tmux sessions have no graphics bit of their own. LaunchServices can
        // still start an app in this user's console session, so query the console owner instead.
        var user: uid_t = 0
        var group: gid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &user, &group) as String? else {
            let status = SCError()
            guard status == kSCStatusOK || status == kSCStatusNoKey else { throw DesktopSessionError.queryFailed(status) }
            return false
        }
        return name != "loginwindow" && name != "_mbsetupuser" && user == getuid()
    }
}

private enum DesktopSessionError: LocalizedError {
    case queryFailed(Int32)

    var errorDescription: String? {
        switch self {
        case let .queryFailed(status): "Unable to check the console desktop session (SystemConfiguration error \(status))."
        }
    }
}
