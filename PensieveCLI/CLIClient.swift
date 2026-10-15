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
        var mayHaveApplied = false
        let networkCommand = ["install", "skill outdated", "skill update"].contains(request.command)
        let replyTimeout = request.command == "sync" || networkCommand
            ? CLIProtocol.syncReplyTimeout : CLIProtocol.commandReplyTimeout
        do {
            let descriptor = try connect(deadline: deadline)
            defer { close(descriptor) }
            let bytes = try SocketTransport.readFrame(descriptor, limit: CLIProtocol.requestLimit,
                timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime))
            let handshake = try validatedHandshake(bytes, isWrite: request.isWrite)
            var request = request
            request.acknowledgeReadiness = handshake.supportsReadiness == true || handshake.supportsCommit == true
            request.requiresCommit = handshake.supportsCommit == true
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
            if request.requiresCommit == true {
                mayHaveApplied = request.isWrite
                try SocketTransport.writeFrame(CLICommandCommit(commit: true), to: descriptor, timeout: 5)
            }
            response = try SocketTransport.readFrame(descriptor, limit: CLIProtocol.replyLimit,
                timeout: replyTimeout)
            return try validatedReply(response)
        } catch let refusal as LaunchRefusal {
            return refusal.reply
        } catch SocketError.timeout {
            return timeoutReply(request: request, startup: waitingForStartup,
                networkCommand: networkCommand, replyTimeout: replyTimeout)
        } catch {
            return .failure("app_unavailable", "\(socketPath): \(error.localizedDescription)",
                hint: mayHaveApplied ? "Check Pensieve before running this command again. Its result could not be received."
                    : launcher.launchRefusal(appPath: appPath, bundleID: bundleID)?.envelope.error?.hint
                        ?? "Open \(appPath), then run this command again.", exit: 3, retryable: !mayHaveApplied)
        }
    }

    private func timeoutReply(request: CLIRequest, startup: Bool, networkCommand: Bool,
                              replyTimeout: TimeInterval) -> CLIReply {
            if !startup {
                if request.command == "sync" {
                    return .failure("sync_still_running", "Sync is still running in Pensieve.",
                        hint: "Run pensieve status to see the result once sync finishes. Avoid starting another sync.", exit: 3)
                }
                if networkCommand {
                    return .failure("command_still_running", "The work is still running in Pensieve.",
                        hint: "Check the result in Pensieve, or run pensieve skill list and pensieve skill show <skill>. "
                            + "Avoid starting the command again while it finishes.", exit: 3)
                }
                let seconds = Int(replyTimeout)
                return .failure("app_unavailable", "Pensieve did not reply to the command within \(seconds) seconds.",
                    hint: "Check Pensieve before running this command again.", exit: 3)
            }
            return .failure("app_starting", "Pensieve has not finished starting.",
                hint: "Wait a moment, then run this command again.", exit: 3, retryable: true)
    }

    private func validatedHandshake(_ bytes: Data, isWrite: Bool) throws -> CLIHandshake {
        let handshake = try JSONDecoder().decode(CLIHandshake.self, from: bytes)
        guard handshake.protocolVersion == CLIProtocol.version else {
            throw LaunchRefusal(reply: .failure("protocol_mismatch", "The app uses a different command protocol.",
                hint: "Use the command bundled with this app.", exit: 3))
        }
        guard fileService.realPath(at: handshake.bundlePath) == appPath else {
            throw LaunchRefusal(reply: .failure("wrong_app", "Another Pensieve copy answered: \(handshake.bundlePath)",
                hint: "Quit that copy and open \(appPath).", exit: 3))
        }
        guard !isWrite || handshake.supportsCommit == true else {
            throw LaunchRefusal(reply: .failure("protocol_mismatch", "The app does not support command admission.",
                hint: "Use the command bundled with this app.", exit: 3))
        }
        return handshake
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
