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

    func refuseBusy(_ client: Int32) {
        guard configure(client) else { return }
        var refusal = handshake
        refusal.busy = true
        try? SocketTransport.writeFrame(refusal, to: client, timeout: min(timeouts.reply, 0.1))
    }

    func serve(_ client: Int32, slot: SocketSessionSlot) {
        guard configure(client) else { return }
        do {
            try SocketTransport.writeFrame(handshake, to: client, timeout: timeouts.reply)
            let bytes = try readRequest(client)
            let request = try JSONDecoder().decode(CLIRequest.self, from: bytes)
            guard request.protocolVersion == CLIProtocol.version else {
                try SocketTransport.writeFrame(CLIReply.failure("protocol_mismatch", "Unsupported protocol version",
                    hint: "Use the command bundled with this app.", exit: 3), to: client, timeout: timeouts.reply)
                return
            }
            try execute(request, client: client, slot: slot)
        } catch {
            switch error {
            case is DecodingError, SocketError.oversized:
                try? SocketTransport.writeFrame(CLIReply.failure("invalid_request", error.localizedDescription,
                    hint: "Use pensieve commands --json.", exit: 64), to: client, timeout: timeouts.reply)
            case is RequestTimeout:
                try? SocketTransport.writeFrame(CLIReply.failure("request_timeout", "The command request did not arrive in time.",
                    hint: "Retry the command when the connection is responsive.", exit: 3, retryable: true),
                    to: client, timeout: timeouts.reply)
            default: return
            }
        }
    }

    private struct RequestTimeout: Error {}

    private func readRequest(_ client: Int32) throws -> Data {
        do {
            return try SocketTransport.readFrame(client, limit: CLIProtocol.requestLimit, timeout: timeouts.request)
        } catch SocketError.timeout { throw RequestTimeout() }
    }

    private func configure(_ client: Int32) -> Bool {
        guard let user = try? credentials.userID(of: client), user == getuid() else { return false }
        var enabled: Int32 = 1
        return setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
            && fcntl(client, F_SETFL, O_NONBLOCK) == 0 && fcntl(client, F_SETFD, FD_CLOEXEC) == 0
    }

    private func execute(_ request: CLIRequest, client: Int32, slot: SocketSessionSlot) throws {
        let ready = DispatchSemaphore(value: 0)
        let result = SocketHandlerResult(slot: slot)
        Task { @MainActor in
            result.reply = await readiness?()
            ready.signal()
        }
        guard ready.wait(timeout: .now() + timeouts.readiness) == .success else {
            try SocketTransport.writeFrame(CLIReply.failure("app_busy", "Pensieve cannot admit this command yet.",
                hint: "Wait for pending work to finish, then retry.", exit: 3, retryable: true),
                to: client, timeout: timeouts.reply)
            return
        }
        if let refusal = result.reply {
            try SocketTransport.writeFrame(refusal, to: client, timeout: timeouts.reply)
            return
        }
        if request.acknowledgeReadiness == true {
            try SocketTransport.writeFrame(CLIReadinessAcknowledgement(ready: true), to: client, timeout: timeouts.reply)
        }
        if request.requiresCommit == true {
            let frame = try readRequest(client)
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
        guard completed.wait(timeout: .now() + timeouts.handler) == .success else {
            try SocketTransport.writeFrame(CLIReply.failure("command_still_running", "The work is still running in Pensieve.",
                hint: "Check Pensieve for the result before running the command again.", exit: 3),
                to: client, timeout: timeouts.reply)
            return
        }
        if let reply = result.reply { try SocketTransport.writeFrame(reply, to: client, timeout: timeouts.reply) }
    }
}

/// A slot outlives its transport when actor work is queued or accepted. Its last owner releases
/// capacity, including the admission finish callback, so timeouts never grow the actor queue.
final class SocketSessionSlot {
    private let release: () -> Void
    init(release: @escaping () -> Void) { self.release = release }
    deinit { release() }
}

private final class SocketHandlerResult {
    let slot: SocketSessionSlot
    init(slot: SocketSessionSlot) { self.slot = slot }
    deinit {
        if let finish {
            let slot = slot
            Task { @MainActor in
                finish()
                withExtendedLifetime(slot) {}
            }
        }
    }
    var reply: CLIReply?
    var finish: (@MainActor () -> Void)?
}
