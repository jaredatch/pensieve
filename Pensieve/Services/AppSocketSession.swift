import Darwin
import Foundation

/// One transport worker owns its descriptor. Semaphore publication keeps handler values off
/// transport queues until the main actor has finished writing them.
struct AppSocketSession {
    let handshake: CLIHandshake
    let timeouts: SocketTimeouts
    let credentials: SocketPeerCredentialReading
    let readiness: AppSocketServer.Readiness?
    let admit: AppSocketServer.Admit?
    let handler: AppSocketServer.Handler

    func serve(_ client: Int32) {
        guard configure(client) else { return }
        do {
            try SocketTransport.writeFrame(handshake, to: client, timeout: timeouts.reply)
            let bytes = try SocketTransport.readFrame(client, limit: CLIProtocol.requestLimit, timeout: timeouts.request)
            let request = try JSONDecoder().decode(CLIRequest.self, from: bytes)
            guard request.protocolVersion == CLIProtocol.version else {
                try SocketTransport.writeFrame(CLIReply.failure("protocol_mismatch", "Unsupported protocol version",
                    hint: "Use the command bundled with this app.", exit: 3), to: client, timeout: timeouts.reply)
                return
            }
            try execute(request, client: client)
        } catch {
            switch error {
            case is DecodingError, SocketError.oversized:
                try? SocketTransport.writeFrame(CLIReply.failure("invalid_request", error.localizedDescription,
                    hint: "Use pensieve commands --json.", exit: 64), to: client, timeout: timeouts.reply)
            default: return
            }
        }
    }

    private func configure(_ client: Int32) -> Bool {
        guard let user = try? credentials.userID(of: client), user == getuid() else { return false }
        var enabled: Int32 = 1
        return setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
            && fcntl(client, F_SETFL, O_NONBLOCK) == 0 && fcntl(client, F_SETFD, FD_CLOEXEC) == 0
    }

    private func execute(_ request: CLIRequest, client: Int32) throws {
        let ready = DispatchSemaphore(value: 0)
        let result = SocketHandlerResult()
        Task { @MainActor in
            result.reply = await readiness?()
            ready.signal()
        }
        ready.wait()
        if let refusal = result.reply {
            try SocketTransport.writeFrame(refusal, to: client, timeout: timeouts.reply)
            return
        }
        if request.acknowledgeReadiness == true {
            try SocketTransport.writeFrame(CLIReadinessAcknowledgement(ready: true), to: client, timeout: timeouts.reply)
        }
        if request.requiresCommit == true {
            let frame = try SocketTransport.readFrame(client, limit: CLIProtocol.requestLimit, timeout: timeouts.request)
            guard try JSONDecoder().decode(CLICommandCommit.self, from: frame).commit else { return }
        } else if request.isWrite {
            try SocketTransport.writeFrame(CLIReply.failure("protocol_mismatch", "Writes require command admission.",
                hint: "Use the command bundled with this app.", exit: 3), to: client, timeout: timeouts.reply)
            return
        }
        // Admission is irrevocable, including when the reply is lost.
        let completed = DispatchSemaphore(value: 0)
        Task { @MainActor in
            let admission = admit?(request)
            result.finish = admission?.finish
            if let refusal = admission?.refusal { result.reply = refusal } else { result.reply = await handler(request) }
            completed.signal()
        }
        completed.wait()
        defer { if let finish = result.finish { Task { @MainActor in finish() } } }
        if let reply = result.reply { try SocketTransport.writeFrame(reply, to: client, timeout: timeouts.reply) }
    }
}

private final class SocketHandlerResult {
    var reply: CLIReply?
    var finish: (@MainActor () -> Void)?
}
