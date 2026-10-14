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
    typealias Readiness = @MainActor () async -> CLIReply?
    struct Admission {
        var refusal: CLIReply?
        var finish: (@MainActor () -> Void)?
    }
    typealias Admit = @MainActor (CLIRequest) -> Admission
    private let source: DispatchSourceRead
    private let listener: SocketListener

    init(path: String, handshake: CLIHandshake, fileService: FileServiceProtocol,
         timeouts: SocketTimeouts = .init(), credentials: SocketPeerCredentialReading = SocketPeerCredentials(),
         readiness: Readiness? = nil, admit: Admit? = nil,
         handler: @escaping Handler) throws {
        var handshake = handshake
        handshake.supportsReadiness = readiness != nil
        handshake.supportsCommit = true
        let listener = try fileService.makeSocketListener(at: path)
        self.listener = listener
        let queue = DispatchQueue(label: "com.jaredatch.pensieve.socket.accept")
        let clients = DispatchQueue(label: "com.jaredatch.pensieve.socket.clients", attributes: .concurrent)
        let slots = DispatchSemaphore(value: 32)
        let session = AppSocketSession(handshake: handshake, timeouts: timeouts,
            credentials: credentials, readiness: readiness, admit: admit, handler: handler)
        source = DispatchSource.makeReadSource(fileDescriptor: listener.descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            while true {
                let client = accept(listener.descriptor, nil, nil)
                guard client >= 0 else {
                    if errno == EMFILE || errno == ENFILE, let source = self?.source {
                        source.suspend()
                        // Retain and balance this suspension even if stop/deinit cancels the source meanwhile.
                        queue.asyncAfter(deadline: .now() + .milliseconds(100)) { source.resume() }
                    }
                    return
                }
                guard slots.wait(timeout: .now()) == .success else { close(client); continue }
                clients.async {
                    defer { close(client); slots.signal() }
                    session.serve(client)
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

}
