import Darwin
import Foundation

struct CLIClient {
    let appPath: String
    let socketPath: String
    let fileService: FileServiceProtocol

    func send(_ request: CLIRequest) -> CLIReply {
        do {
            let descriptor = try SocketTransport.connect(to: socketPath)
            defer { close(descriptor) }
            let bytes = try SocketTransport.readFrame(descriptor, limit: CLIProtocol.requestLimit, timeout: 5)
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
            let response = try SocketTransport.readFrame(descriptor, limit: CLIProtocol.replyLimit, timeout: 30)
            let reply = try JSONDecoder().decode(CLIReply.self, from: response)
            guard reply.envelope.schema == CLIProtocol.version,
                  [0, 1, 2, 3, 4, 5, 64, 130].contains(reply.exitCode),
                  reply.envelope.ok == (reply.envelope.error == nil) else {
                return .failure("protocol_mismatch", "Invalid app response.",
                    hint: "Use the command bundled with this app.", exit: 3)
            }
            return reply
        } catch {
            return .failure("app_unavailable", "\(socketPath): \(error.localizedDescription)",
                hint: "Open \(appPath), then run this command again.", exit: 3, retryable: true)
        }
    }
}
