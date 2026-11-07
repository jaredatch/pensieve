import Darwin
import Foundation

protocol AppSocketServing: AnyObject {
    func stop()
}

struct SocketTimeouts {
    var request: TimeInterval = 5
    var reply: TimeInterval = 5
    var readiness: TimeInterval = CLIProtocol.readyTimeout
    var handler: TimeInterval = CLIProtocol.syncReplyTimeout
}

/// Transport queues never touch SwiftData. A decoded request crosses to the handler's main actor.
/// Disconnecting a client only ends transport work; an accepted handler task runs to completion.
final class AppSocketServer: AppSocketServing {
    typealias Handler = @MainActor (CLIRequest) async -> CLIReply
    typealias Readiness = @MainActor () async -> CLIReply?
    struct Admission {
        var refusal: CLIReply?
        var finish: (@MainActor () -> Void)?
    }
    typealias Admit = @MainActor (CLIRequest) -> Admission
    private let source: DispatchSourceRead
    private let lease: ListenerLease
    private let released = DispatchGroup()

    /// Shared with the cancel handler, which alone releases the listener after accept work drains.
    private final class ListenerLease {
        var listener: SocketListener?

        init(_ listener: SocketListener) { self.listener = listener }
    }

    init(path: String, handshake: CLIHandshake, fileService: FileServiceProtocol,
         timeouts: SocketTimeouts = .init(), credentials: SocketPeerCredentialReading = SocketPeerCredentials(),
         readiness: Readiness? = nil, admit: Admit? = nil,
         handler: @escaping Handler) throws {
        var handshake = handshake
        handshake.supportsReadiness = readiness != nil
        handshake.supportsCommit = true
        let listener = try fileService.makeSocketListener(at: path)
        let lease = ListenerLease(listener)
        self.lease = lease
        let descriptor = listener.descriptor
        let queue = DispatchQueue(label: "com.jaredatch.pensieve.socket.accept")
        let clients = DispatchQueue(label: "com.jaredatch.pensieve.socket.clients", attributes: .concurrent)
        let slots = DispatchSemaphore(value: 32)
        let session = AppSocketSession(handshake: handshake, timeouts: timeouts,
            credentials: credentials, readiness: readiness, admit: admit, handler: handler)
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            while true {
                guard self?.source.isCancelled == false else { return }
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else {
                    if errno == EMFILE || errno == ENFILE, let source = self?.source {
                        source.suspend()
                        // Retain and balance this suspension even if stop/deinit cancels the source meanwhile.
                        queue.asyncAfter(deadline: .now() + .milliseconds(100)) { source.resume() }
                    }
                    return
                }
                guard slots.wait(timeout: .now()) == .success else {
                    session.refuseBusy(client)
                    close(client)
                    continue
                }
                let slot = SocketSessionSlot { slots.signal() }
                clients.async {
                    defer { close(client) }
                    session.serve(client, slot: slot)
                }
            }
        }
        // Retain the lease until cancellation has drained the event handler, avoiding descriptor reuse races.
        let released = released
        released.enter()
        source.setCancelHandler {
            lease.listener = nil
            released.leave()
        }
        source.resume()
    }

    /// Releases the endpoint before returning, without waiting for accepted client sessions.
    func stop() {
        source.cancel()
        released.wait()
    }

    deinit {
        // The last reference can disappear on the accept queue, so only explicit stop() may wait.
        source.cancel()
    }

}
