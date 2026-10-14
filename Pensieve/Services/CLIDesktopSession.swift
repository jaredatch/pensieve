import Foundation
import Security

protocol CLIDesktopSessionReading {
    func hasGraphicAccess() throws -> Bool
}

struct CLIDesktopSession: CLIDesktopSessionReading {
    func hasGraphicAccess() throws -> Bool {
        var session: SecuritySessionId = 0
        var attributes = SessionAttributeBits()
        let status = SessionGetInfo(callerSecuritySession, &session, &attributes)
        guard status == errSecSuccess else { throw DesktopSessionError.queryFailed(status) }
        return attributes.contains(.sessionHasGraphicAccess)
    }
}

private enum DesktopSessionError: LocalizedError {
    case queryFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .queryFailed(status): "Unable to check the desktop session (Security error \(status))."
        }
    }
}
