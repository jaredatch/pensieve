import Darwin
import Foundation

protocol AppSocketServing: AnyObject {
    func stop()
}

struct SocketTimeouts {
    var request: TimeInterval = 5
    var reply: TimeInterval = 5
}

/// Transport queues never touch SwiftData. A decoded request crosses to the handler's main actor.
/// Disconnecting a client only ends transport work; an accepted handler task runs to completion.
final class AppSocketServer: AppSocketServing {
    typealias Handler = @MainActor (CLIRequest) async -> CLIReply
    private let source: DispatchSourceRead
    private let listener: SocketListener

    init(path: String, handshake: CLIHandshake, fileService: FileServiceProtocol,
         timeouts: SocketTimeouts = .init(), credentials: SocketPeerCredentialReading = SocketPeerCredentials(),
         handler: @escaping Handler) throws {
        let listener = try fileService.makeSocketListener(at: path)
        self.listener = listener
        let queue = DispatchQueue(label: "com.jaredatch.pensieve.socket.accept")
        let clients = DispatchQueue(label: "com.jaredatch.pensieve.socket.clients", attributes: .concurrent)
        let slots = DispatchSemaphore(value: 32)
        let requestTimeout = timeouts.request
        let replyTimeout = timeouts.reply
        source = DispatchSource.makeReadSource(fileDescriptor: listener.descriptor, queue: queue)
        source.setEventHandler {
            while true {
                let client = accept(listener.descriptor, nil, nil)
                guard client >= 0 else { return }
                guard slots.wait(timeout: .now()) == .success else { close(client); continue }
                clients.async {
                    defer { close(client); slots.signal() }
                    Self.serve(client, handshake: handshake, requestTimeout: requestTimeout,
                               replyTimeout: replyTimeout, credentials: credentials, handler: handler)
                }
            }
        }
        // Retain the lease until cancellation has drained the event handler, avoiding descriptor reuse races.
        source.setCancelHandler { withExtendedLifetime(listener) {} }
        source.resume()
    }

    func stop() {
        source.cancel()
        listener.removeOwnedPath()
    }

    deinit {
        source.cancel()
        listener.removeOwnedPath()
    }

    private static func serve(_ client: Int32, handshake: CLIHandshake, requestTimeout: TimeInterval,
                              replyTimeout: TimeInterval, credentials: SocketPeerCredentialReading,
                              handler: @escaping Handler) {
        guard let user = try? credentials.userID(of: client), user == getuid() else { return }
        var enabled: Int32 = 1
        guard setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(client, F_SETFL, O_NONBLOCK) == 0,
              fcntl(client, F_SETFD, FD_CLOEXEC) == 0 else { return }
        do {
            try SocketTransport.writeFrame(handshake, to: client, timeout: replyTimeout)
            let bytes = try SocketTransport.readFrame(client, limit: CLIProtocol.requestLimit, timeout: requestTimeout)
            let request = try JSONDecoder().decode(CLIRequest.self, from: bytes)
            guard request.protocolVersion == CLIProtocol.version else {
                try SocketTransport.writeFrame(CLIReply.failure("protocol_mismatch", "Unsupported protocol version",
                    hint: "Use the command bundled with this app.", exit: 3), to: client, timeout: replyTimeout)
                return
            }
            let completed = DispatchSemaphore(value: 0)
            let result = SocketHandlerResult()
            Task { @MainActor in
                result.reply = await handler(request)
                completed.signal()
            }
            completed.wait()
            if let reply = result.reply { try SocketTransport.writeFrame(reply, to: client, timeout: replyTimeout) }
        } catch {
            // A malformed or expired connection gets its own bounded error attempt, then closes.
            try? SocketTransport.writeFrame(CLIReply.failure("invalid_request", error.localizedDescription,
                hint: "Use pensieve commands --json.", exit: 64), to: client, timeout: replyTimeout)
        }
    }
}

/// The semaphore publishes the main-actor result before the transport worker reads it.
private final class SocketHandlerResult {
    var reply: CLIReply?
}
