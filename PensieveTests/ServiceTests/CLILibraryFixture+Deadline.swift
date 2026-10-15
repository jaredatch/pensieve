import Darwin
import Foundation
import XCTest
@testable import Pensieve

extension CLILibraryFixture {
    nonisolated static func readPrompt(from handle: FileHandle) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + TestWait.hostedActionTimeoutSeconds
        var bytes = Data()
        while ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 100) > 0 {
                let chunk = handle.availableData
                guard !chunk.isEmpty else { throw CocoaError(.fileReadUnknown) }
                bytes.append(chunk)
                if (String(data: bytes, encoding: .utf8) ?? "").contains("Apply this plan?") { return bytes }
            }
        }
        throw CocoaError(.fileReadUnknown)
    }

    /// The app reaches its real network operation. Interpose the child's kernel wait only,
    /// recording the deadline it requested before expiring that wait early.
    func assertNetworkDeadline(_ arguments: [String], remote: CLILibraryRemoteGate) async throws {
        let source = root + "/poll.c", dylib = root + "/poll.dylib", receipt = root + "/poll-receipt"
        try files.writeFile(at: source, content: """
        #include <poll.h>
        #include <stdio.h>
        #include <stdlib.h>
        static int expire_poll(struct pollfd *fds, nfds_t count, int milliseconds) {
            if (milliseconds > 25000 && count == 1 && (fds[0].events & POLLIN)) {
                FILE *receipt = fopen(getenv("PENSIEVE_POLL_RECEIPT"), "w");
                if (receipt) { fprintf(receipt, "%d", milliseconds); fclose(receipt); }
                return poll(fds, count, 100);
            }
            return poll(fds, count, milliseconds);
        }
        __attribute__((used)) static struct { const void *replacement; const void *original; }
        interpose_poll __attribute__((section("__DATA,__interpose"))) = { (void *)expire_poll, (void *)poll };
        """)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = ["-dynamiclib", source, "-o", dylib]
        let result = try await BlockingWork.run { try CLIProcessProbe.run(compiler, timeout: 30) }
        XCTAssertEqual(result.status, 0)
        remote.arm()
        defer { remote.gate.open() }
        let reply = try await run(arguments, exit: 3, environment: [
            "DYLD_INSERT_LIBRARIES": dylib, "PENSIEVE_POLL_RECEIPT": receipt])
        XCTAssertEqual(remote.gate.waiterCount, 1, "The admitted command is still executing its real network work")
        let milliseconds = try XCTUnwrap(Int(files.readFile(at: receipt)))
        XCTAssertGreaterThanOrEqual(milliseconds, 599_900, "Network reply wait is ten minutes")
        XCTAssertLessThanOrEqual(milliseconds, 600_001)
        XCTAssertEqual(reply.error?.code, "command_still_running")
        XCTAssertEqual(reply.error?.retryable, false)
        XCTAssertTrue(reply.error?.message.contains("still running in Pensieve") == true)
        remote.gate.open()
        await TestWait.until(failureMessage: "Accepted work finishes after the CLI wait ends") {
            self.paths.syncSteps.pendingCount == 0
        }
    }
}
