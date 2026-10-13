import Darwin
import XCTest
@testable import Pensieve

@MainActor
final class AppSocketServerTests: XCTestCase {
    func testHandshakePermissionsAndRealPeerRequest() async throws {
        let directory = try SocketTestDirectory()
        let path = directory.path + "/s"
        let server = try server(at: path)
        defer { server.stop() }
        var status = stat()
        XCTAssertEqual(lstat(path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o777, 0o600)
        XCTAssertEqual(status.st_uid, getuid())
        let reply = try await exchange(path)
        XCTAssertEqual(reply.envelope, CLIReply.success(.string("answered")).envelope)
        let identities: [uid_t?] = [getuid() + 1, nil]
        for (index, identity) in identities.enumerated() {
            let deniedPath = directory.path + "/denied" + String(index)
            let denied = try self.server(at: deniedPath, credentials: ReportedSocketPeer(user: identity))
            defer { denied.stop() }
            try await BlockingWork.run {
                let client = try SocketTransport.connect(to: deniedPath)
                defer { close(client) }
                XCTAssertThrowsError(try SocketTransport.readFrame(client, limit: 1_024,
                    timeout: TestWait.hostedActionTimeoutSeconds)) { error in
                    guard case SocketError.disconnected = error else {
                        return XCTFail("Denied credentials must close before a handshake: \(error)")
                    }
                }
            }
        }

    }

    func testBadRequestsAndTotalSendDeadlineDoNotBlockNextClient() async throws {
        let directory = try SocketTestDirectory()
        let path = directory.path + "/s"
        let server = try server(at: path)
        defer { server.stop() }
        for kind in ["oversized", "malformed", "protocol", "silent", "trickle"] {
            try await BlockingWork.run {
                let client = try SocketTransport.connect(to: path)
                defer { close(client) }
                _ = try SocketTransport.readFrame(client, limit: 1_024, timeout: TestWait.hostedActionTimeoutSeconds)
                let started = ProcessInfo.processInfo.systemUptime
                switch kind {
                case "oversized":
                    try SocketTransport.writeFrame(String(repeating: "x", count: CLIProtocol.requestLimit + 1),
                        to: client, timeout: TestWait.hostedActionTimeoutSeconds)
                case "malformed": _ = "bad\n".withCString { send(client, $0, 4, 0) }
                case "protocol":
                    try SocketTransport.writeFrame(CLIRequest(protocolVersion: 999, command: "skill list"),
                        to: client, timeout: TestWait.hostedActionTimeoutSeconds)
                case "trickle":
                    for _ in 0..<6 {
                        _ = "{".withCString { send(client, $0, 1, 0) }
                        Thread.sleep(forTimeInterval: 0.08)
                    }
                default: break
                }
                let receiveTimeout = kind == "trickle" ? 0.05 : TestWait.hostedActionTimeoutSeconds // upper-bound: frame deadline
                let bytes = try SocketTransport.readFrame(client, limit: 4_096, timeout: receiveTimeout)
                let reply = try JSONDecoder().decode(CLIReply.self, from: bytes)
                XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.5, kind)
                XCTAssertFalse(reply.envelope.ok, kind)
                if kind == "oversized" { XCTAssertTrue(reply.envelope.error?.message.contains("size limit") == true) }
                XCTAssertEqual(reply.envelope.error?.code, kind == "protocol" ? "protocol_mismatch" : "invalid_request")
            }
            let next = try await exchange(path)
            XCTAssertTrue(next.envelope.ok, kind)
        }
    }

    func testUnreadReplyTimesOutWhileAnotherClientIsServed() async throws {
        let directory = try SocketTestDirectory()
        let path = directory.path + "/s"
        let server = try server(at: path) { request in
            .success(.string(request.command == "large" ? String(repeating: "x", count: 8 * 1_024 * 1_024) : "answered"))
        }
        defer { server.stop() }
        let client = try SocketTransport.connect(to: path)
        defer { close(client) }
        try await BlockingWork.run {
            _ = try SocketTransport.readFrame(client, limit: 1_024, timeout: TestWait.hostedActionTimeoutSeconds)
            try SocketTransport.writeFrame(CLIRequest(command: "large"), to: client, timeout: TestWait.hostedActionTimeoutSeconds)
        }
        let next = try await exchange(path)
        XCTAssertTrue(next.envelope.ok)
        try await BlockingWork.run {
            Thread.sleep(forTimeInterval: 0.6)
            XCTAssertThrowsError(try SocketTransport.readFrame(client, limit: CLIProtocol.replyLimit,
                                                               timeout: TestWait.hostedActionTimeoutSeconds))
        }
    }

    func testAcceptedHandlerFinishesAfterClientDisconnects() async throws {
        let directory = try SocketTestDirectory()
        let path = directory.path + "/s"
        let accepted = expectation(description: "handler accepted")
        let completed = expectation(description: "handler finished")
        let server = try server(at: path) { _ in
            accepted.fulfill()
            try? await Task.sleep(for: .milliseconds(100))
            completed.fulfill()
            return .success(.null)
        }
        defer { server.stop() }
        let client = try SocketTransport.connect(to: path)
        try await BlockingWork.run {
            _ = try SocketTransport.readFrame(client, limit: 1_024, timeout: TestWait.hostedActionTimeoutSeconds)
            try SocketTransport.writeFrame(CLIRequest(command: "accepted"), to: client,
                timeout: TestWait.hostedActionTimeoutSeconds)
        }
        await fulfillment(of: [accepted], timeout: TestWait.hostedActionTimeoutSeconds)
        close(client)
        await fulfillment(of: [completed], timeout: TestWait.hostedActionTimeoutSeconds)
    }

    private func server(at path: String, credentials: SocketPeerCredentialReading = SocketPeerCredentials(),
                        handler: @escaping AppSocketServer.Handler = { _ in .success(.string("answered")) }
    ) throws -> AppSocketServer {
        try AppSocketServer(path: path, handshake: CLIHandshake(bundlePath: "/fixture/Pensieve.app", appVersion: "1.2.3"),
            fileService: FileService(), timeouts: .init(request: 0.2, reply: 0.2), credentials: credentials, handler: handler)
    }

    private func exchange(_ path: String) async throws -> CLIReply {
        try await BlockingWork.run {
            let client = try SocketTransport.connect(to: path)
            defer { close(client) }
            let bytes = try SocketTransport.readFrame(client, limit: 1_024, timeout: TestWait.hostedActionTimeoutSeconds)
            let handshake = try JSONDecoder().decode(CLIHandshake.self, from: bytes)
            XCTAssertEqual(handshake.bundlePath, "/fixture/Pensieve.app")
            XCTAssertEqual(handshake.protocolVersion, CLIProtocol.version)
            XCTAssertEqual(handshake.appVersion, "1.2.3")
            try SocketTransport.writeFrame(CLIRequest(command: "skill list"), to: client,
                timeout: TestWait.hostedActionTimeoutSeconds)
            return try JSONDecoder().decode(CLIReply.self, from: SocketTransport.readFrame(client,
                limit: CLIProtocol.replyLimit, timeout: TestWait.hostedActionTimeoutSeconds))
        }
    }
}

/// Reports the kernel-query result only; the real server still owns admission and socket I/O.
private struct ReportedSocketPeer: SocketPeerCredentialReading {
    let user: uid_t?

    func userID(of descriptor: Int32) throws -> uid_t {
        guard let user else { throw SocketError.system("credential query", EACCES) }
        return user
    }
}
