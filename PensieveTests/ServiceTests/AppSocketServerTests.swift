import Darwin
import XCTest
@testable import Pensieve

@MainActor
final class AppSocketServerTests: XCTestCase {
    func testHandshakePermissionsAndRealPeerRequest() async throws {
        // A stream may deliver the handshake/readiness/reply in one recv. Reading one frame
        // must preserve the next, regardless of the sender's write boundaries.
        try await BlockingWork.run {
            var pair: [Int32] = [-1, -1]
            XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
            defer { close(pair[0]); close(pair[1]) }
            let burst = Data("{\"ready\":true}\n{\"ok\":true}\n".utf8)
            let sent = burst.withUnsafeBytes { send(pair[1], $0.baseAddress, $0.count, 0) }
            XCTAssertEqual(sent, burst.count)
            shutdown(pair[1], SHUT_WR)
            for expected in ["{\"ready\":true}", "{\"ok\":true}"] {
                let frame = try SocketTransport.readFrame(pair[0], limit: 1_024, timeout: TestWait.hostedActionTimeoutSeconds)
                XCTAssertEqual(String(data: frame, encoding: .utf8), expected)
            }
        }
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
                if kind == "silent" || kind == "trickle" {
                    let bytes = try SocketTransport.readFrame(client, limit: 4_096,
                        timeout: TestWait.hostedActionTimeoutSeconds)
                    let reply = try JSONDecoder().decode(CLIReply.self, from: bytes)
                    XCTAssertEqual(reply.envelope.error?.code, "request_timeout")
                    XCTAssertEqual(reply.envelope.error?.retryable, true)
                    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.5, kind)
                    return
                }
                let bytes = try SocketTransport.readFrame(client, limit: 4_096, timeout: TestWait.hostedActionTimeoutSeconds)
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
        let finished = expectation(description: "large reply transport finished")
        let server = try server(at: path, admit: { request in
            if request.command == "large" { return .init(finish: { finished.fulfill() }) }
            return .init()
        }, handler: { request in
            .success(.string(request.command == "large" ? String(repeating: "x", count: 8 * 1_024 * 1_024) : "answered"))
        })
        defer { server.stop() }
        let client = try SocketTransport.connect(to: path)
        defer { close(client) }
        try await BlockingWork.run {
            _ = try SocketTransport.readFrame(client, limit: 1_024, timeout: TestWait.hostedActionTimeoutSeconds)
            try SocketTransport.writeFrame(CLIRequest(command: "large"), to: client, timeout: TestWait.hostedActionTimeoutSeconds)
            try SocketTransport.wait(client, events: Int16(POLLIN),
                                     deadline: SocketTransport.deadline(after: TestWait.hostedActionTimeoutSeconds))
        }
        let next = try await exchange(path)
        XCTAssertTrue(next.envelope.ok)
        await fulfillment(of: [finished], timeout: TestWait.hostedActionTimeoutSeconds)
        try await BlockingWork.run {
            var received = Data()
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let deadline = SocketTransport.deadline(after: TestWait.hostedActionTimeoutSeconds)
            while true {
                let count = recv(client, &bytes, bytes.count, 0)
                if count > 0 { received.append(contentsOf: bytes.prefix(count)); continue }
                if count == 0 { break }
                guard errno == EAGAIN || errno == EWOULDBLOCK else { throw SocketError.system("recv", errno) }
                try SocketTransport.wait(client, events: Int16(POLLIN), deadline: deadline)
            }
            XCTAssertFalse(received.isEmpty)
            XCTAssertLessThan(received.count, 8 * 1_024 * 1_024)
            XCTAssertFalse(received.contains(10), "A partial reply must not acquire another frame's terminator")
            let text = try XCTUnwrap(String(data: received, encoding: .utf8))
            XCTAssertFalse(text.contains("invalid_request"))
        }
    }

    func testTimedOutTransportsKeepQueuedAndAcceptedWorkBounded() async throws {
        for beforeAdmission in [true, false] {
            let directory = try SocketTestDirectory()
            let path = directory.path + "/s"
            let gate = TestWait.Gate(owner: self)
            defer { for _ in 0..<32 { gate.open() } }
            var finished = 0
            let wait: @MainActor () async -> Void = {
                await BlockingWork.run { try? gate.wait() }
                finished += 1
            }
            let server = try AppSocketServer(path: path,
                handshake: CLIHandshake(bundlePath: "/fixture/Pensieve.app", appVersion: "1"),
                fileService: directory.files,
                timeouts: .init(request: 0.2, reply: 0.2, readiness: 0.1, handler: 0.1),
                readiness: { if beforeAdmission { await wait() }; return nil },
                handler: { _ in if !beforeAdmission { await wait() }; return .success(.null) })
            defer { server.stop() }
            for _ in 0..<32 {
                let response = try await BlockingWork.run {
                    let client = try SocketTransport.connect(to: path)
                    defer { close(client) }
                    _ = try SocketTransport.readFrame(client, limit: 4_096, timeout: TestWait.hostedActionTimeoutSeconds)
                    try SocketTransport.writeFrame(CLIRequest(command: "skill list"), to: client,
                        timeout: TestWait.hostedActionTimeoutSeconds)
                    // upper-bound: a parked worker must return before the deliberately held work finishes.
                    return try JSONDecoder().decode(CLIReply.self,
                        from: SocketTransport.readFrame(client, limit: 4_096, timeout: 2)) // upper-bound: parked slot
                }
                XCTAssertEqual(response.envelope.error?.code, beforeAdmission ? "app_busy" : "command_still_running")
                XCTAssertEqual(response.envelope.error?.retryable, beforeAdmission)
            }
            let refused = try await BlockingWork.run {
                let client = try SocketTransport.connect(to: path)
                defer { close(client) }
                return try JSONSerialization.jsonObject(with: SocketTransport.readFrame(client, limit: 4_096,
                    timeout: TestWait.hostedActionTimeoutSeconds)) as? [String: Any]
            }
            XCTAssertEqual(refused?["busy"] as? Bool, true, "Timed-out transports cannot free queued-handler capacity")
            XCTAssertEqual(finished, 0)
            for _ in 0..<32 { gate.open() }
            await TestWait.until(failureMessage: "Accepted work must finish after its transport ends") { finished == 32 }
        }
    }

    func testAcceptedHandlerFinishesAfterClientDisconnects() async throws {
        let directory = try SocketTestDirectory()
        let path = directory.path + "/s"
        let accepted = expectation(description: "handler accepted")
        let completed = expectation(description: "handler finished")
        let server = try server(at: path) { _ in
            accepted.fulfill()
            defer { completed.fulfill() }
            do {
                try await Task.sleep(for: .milliseconds(100))
                try Task.checkCancellation()
                try directory.files.writeFile(at: directory.path + "/applied", content: "finished")
            } catch {
                XCTFail("Accepted handler must finish without cancellation: \(error)")
            }
            return .success(.null)
        }
        defer { server.stop() }
        let client = try SocketTransport.connect(to: path)
        try await BlockingWork.run {
            _ = try SocketTransport.readFrame(client, limit: 1_024, timeout: TestWait.hostedActionTimeoutSeconds)
            try SocketTransport.writeFrame(CLIRequest(command: "deploy", acknowledgeReadiness: true, requiresCommit: true),
                to: client, timeout: TestWait.hostedActionTimeoutSeconds)
            _ = try SocketTransport.readFrame(client, limit: 1_024, timeout: TestWait.hostedActionTimeoutSeconds)
            try SocketTransport.writeFrame(CLICommandCommit(commit: true), to: client,
                timeout: TestWait.hostedActionTimeoutSeconds)
        }
        await fulfillment(of: [accepted], timeout: TestWait.hostedActionTimeoutSeconds)
        close(client)
        await fulfillment(of: [completed], timeout: TestWait.hostedActionTimeoutSeconds)
        XCTAssertEqual(try directory.files.readFile(at: directory.path + "/applied"), "finished")
    }

    func testUncommittedCommandNeverRunsAfterReadiness() async throws {
        let directory = try SocketTestDirectory()
        let path = directory.path + "/s"
        var applied = 0
        let server = try AppSocketServer(path: path,
            handshake: CLIHandshake(bundlePath: "/fixture/Pensieve.app", appVersion: "1"),
            fileService: FileService(), timeouts: .init(request: 0.2, reply: 0.2),
            readiness: { nil }, handler: { _ in applied += 1; return .success(.null) })
        defer { server.stop() }
        try await BlockingWork.run {
            let client = try SocketTransport.connect(to: path)
            defer { close(client) }
            _ = try SocketTransport.readFrame(client, limit: 1_024, timeout: TestWait.hostedActionTimeoutSeconds)
            try SocketTransport.writeFrame(CLIValue.object([
                "protocolVersion": .number(1), "command": .string("deploy"),
                "arguments": .array([]), "content": .bool(false),
                "acknowledgeReadiness": .bool(true), "requiresCommit": .bool(true)
            ]), to: client, timeout: TestWait.hostedActionTimeoutSeconds)
            let ready = try SocketTransport.readFrame(client, limit: 1_024, timeout: TestWait.hostedActionTimeoutSeconds)
            XCTAssertTrue(try JSONDecoder().decode(CLIReadinessAcknowledgement.self, from: ready).ready)
            // A client that expires its startup budget never authorizes the write.
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(applied, 0, "Readiness alone must never accept a write")
    }

    private func server(at path: String, credentials: SocketPeerCredentialReading = SocketPeerCredentials(),
                        admit: AppSocketServer.Admit? = nil,
                        handler: @escaping AppSocketServer.Handler = { _ in .success(.string("answered")) }
    ) throws -> AppSocketServer {
        try AppSocketServer(path: path, handshake: CLIHandshake(bundlePath: "/fixture/Pensieve.app", appVersion: "1.2.3"),
            fileService: FileService(), timeouts: .init(request: 0.2, reply: 0.2), credentials: credentials, admit: admit,
            handler: handler)
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
