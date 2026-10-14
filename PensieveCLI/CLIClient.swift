import Darwin
import Foundation

struct CLIClient {
    let appPath: String
    let socketPath: String
    let fileService: FileServiceProtocol
    let launcher: CLIAppLaunching
    let bundleID: String

    func send(_ request: CLIRequest) -> CLIReply {
        let deadline = SocketTransport.deadline(after: CLIProtocol.readyTimeout)
        do {
            let descriptor = try connect(deadline: deadline)
            defer { close(descriptor) }
            let bytes = try SocketTransport.readFrame(descriptor, limit: CLIProtocol.requestLimit,
                timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime))
            let handshake = try JSONDecoder().decode(CLIHandshake.self, from: bytes)
            guard handshake.protocolVersion == CLIProtocol.version else {
                return .failure("protocol_mismatch", "The app uses a different command protocol.",
                    hint: "Use the command bundled with this app.", exit: 3)
            }
            guard fileService.realPath(at: handshake.bundlePath) == appPath else {
                return .failure("wrong_app", "Another Pensieve copy answered: \(handshake.bundlePath)",
                    hint: "Quit that copy and open \(appPath).", exit: 3)
            }
            try SocketTransport.writeFrame(request, to: descriptor, timeout: 5)
            let response = try SocketTransport.readFrame(descriptor, limit: CLIProtocol.replyLimit,
                timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime))
            let reply = try JSONDecoder().decode(CLIReply.self, from: response)
            guard reply.envelope.schema == CLIProtocol.version,
                  [0, 1, 2, 3, 4, 5, 64, 130].contains(reply.exitCode),
                  reply.envelope.ok == (reply.envelope.error == nil) else {
                return .failure("protocol_mismatch", "Invalid app response.",
                    hint: "Use the command bundled with this app.", exit: 3)
            }
            return reply
        } catch let refusal as LaunchRefusal {
            return refusal.reply
        } catch SocketError.timeout {
            return .failure("app_starting", "Pensieve has not finished starting.",
                hint: "Wait a moment, then run this command again.", exit: 3, retryable: true)
        } catch {
            return .failure("app_unavailable", "\(socketPath): \(error.localizedDescription)",
                hint: "Open \(appPath), then run this command again.", exit: 3, retryable: true)
        }
    }

    private func connect(deadline: TimeInterval) throws -> Int32 {
        do {
            return try SocketTransport.connect(to: socketPath,
                timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime))
        } catch let SocketError.system(_, code) {
            guard code == ENOENT || code == ECONNREFUSED else { throw SocketError.system(socketPath, code) }
        }
        if let refusal = launcher.launch(appPath: appPath, bundleID: bundleID, deadline: deadline) {
            throw LaunchRefusal(reply: refusal)
        }
        while ProcessInfo.processInfo.systemUptime < deadline {
            do {
                return try SocketTransport.connect(to: socketPath,
                    timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime))
            } catch let SocketError.system(_, code) {
                guard code == ENOENT || code == ECONNREFUSED else { throw SocketError.system(socketPath, code) }
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw SocketError.timeout
    }
}

private struct LaunchRefusal: Error {
    let reply: CLIReply
}
