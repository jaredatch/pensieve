import Foundation
import Darwin
import Security
import SystemConfiguration

protocol CLIDesktopSessionReading {
    func hasGraphicAccess() throws -> Bool
}

struct CLIDesktopSession: CLIDesktopSessionReading {
    func hasGraphicAccess() throws -> Bool {
        // A GUI session stays usable after Fast User Switching moves it off the console.
        var session: SecuritySessionId = 0
        var attributes = SessionAttributeBits()
        let status = SessionGetInfo(callerSecuritySession, &session, &attributes)
        if status == errSecSuccess && attributes.contains(.sessionHasGraphicAccess) { return true }
        // SSH and SSH-born tmux have no graphics bit. The user's console desktop also suffices.
        if try consoleBelongsToCurrentUser() { return true }
        guard status == errSecSuccess else { throw DesktopSessionError.securityQueryFailed(status) }
        return false
    }

    private func consoleBelongsToCurrentUser() throws -> Bool {
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
    case securityQueryFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .queryFailed(status): "Unable to check the console desktop session (SystemConfiguration error \(status))."
        case let .securityQueryFailed(status): "Unable to check the desktop session (Security error \(status))."
        }
    }
}
