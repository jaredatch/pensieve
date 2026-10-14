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
        var waitingForStartup = true
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
            var request = request
            request.acknowledgeReadiness = handshake.supportsReadiness == true
            try SocketTransport.writeFrame(request, to: descriptor, timeout: 5)
            var response: Data
            if request.acknowledgeReadiness == true {
                response = try SocketTransport.readFrame(descriptor, limit: CLIProtocol.replyLimit,
                    timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime))
                if (try? JSONDecoder().decode(CLIReadinessAcknowledgement.self, from: response))?.ready != true {
                    return try validatedReply(response)
                }
            }
            waitingForStartup = false
            response = try SocketTransport.readFrame(descriptor, limit: CLIProtocol.replyLimit,
                timeout: CLIProtocol.commandReplyTimeout)
            return try validatedReply(response)
        } catch let refusal as LaunchRefusal {
            return refusal.reply
        } catch SocketError.timeout {
            if !waitingForStartup {
                let seconds = Int(CLIProtocol.commandReplyTimeout)
                return .failure("app_unavailable", "Pensieve did not reply to the command within \(seconds) seconds.",
                    hint: "Check Pensieve before running this command again.", exit: 3)
            }
            return .failure("app_starting", "Pensieve has not finished starting.",
                hint: "Wait a moment, then run this command again.", exit: 3, retryable: true)
        } catch {
            return .failure("app_unavailable", "\(socketPath): \(error.localizedDescription)",
                hint: launcher.launchRefusal(appPath: appPath, bundleID: bundleID)?.envelope.error?.hint
                    ?? "Open \(appPath), then run this command again.", exit: 3, retryable: true)
        }
    }

    private func validatedReply(_ response: Data) throws -> CLIReply {
        let reply = try JSONDecoder().decode(CLIReply.self, from: response)
        guard reply.envelope.schema == CLIProtocol.version,
              [0, 1, 2, 3, 4, 5, 64, 130].contains(reply.exitCode),
              reply.envelope.ok == (reply.envelope.error == nil) else {
            return .failure("protocol_mismatch", "Invalid app response.",
                hint: "Use the command bundled with this app.", exit: 3)
        }
        return reply
    }

    private func connect(deadline: TimeInterval) throws -> Int32 {
        var lastError: Error = SocketError.timeout
        do {
            return try SocketTransport.connect(to: socketPath,
                timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime))
        } catch let SocketError.system(_, code) {
            guard code == ENOENT || code == ECONNREFUSED else { throw SocketError.system(socketPath, code) }
            lastError = SocketError.system("connect", code)
        } catch SocketError.timeout { throw connectionTimeout(lastError) }
        if let refusal = launcher.launch(appPath: appPath, bundleID: bundleID, deadline: deadline) {
            throw LaunchRefusal(reply: refusal)
        }
        while ProcessInfo.processInfo.systemUptime < deadline {
            do {
                return try SocketTransport.connect(to: socketPath,
                    timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime))
            } catch let SocketError.system(_, code) {
                guard code == ENOENT || code == ECONNREFUSED else { throw SocketError.system(socketPath, code) }
                lastError = SocketError.system("connect", code)
            } catch SocketError.timeout { lastError = SocketError.timeout; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw connectionTimeout(lastError)
    }

    private func connectionTimeout(_ error: Error) -> LaunchRefusal {
        LaunchRefusal(reply: .failure("app_starting",
            "Pensieve has not finished starting. \(socketPath): \(error.localizedDescription)",
            hint: "Wait a moment, then run this command again.", exit: 3, retryable: true))
    }
}

private struct LaunchRefusal: Error {
    let reply: CLIReply
}
