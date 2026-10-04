import Darwin
import XCTest
@testable import Pensieve

extension ThirdPartyNoticesTests {
    func testCreditsReadFailureKillsAndReapsChild() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import time; time.sleep(30)"]
        var child: pid_t = 0
        var launchedChild: Process?
        XCTAssertThrowsError(try runCreditsProcess(process, readStdout: { launched, _ in
            child = launched.processIdentifier
            launchedChild = launched
            throw CocoaError(.fileReadUnknown)
        }))
        guard child > 0 else { return XCTFail("The read refusal must follow a successful child launch") }
        let alive = kill(child, 0)
        let waited = waitpid(child, nil, WNOHANG)
        let waitError = errno
        // Clean a broken helper's live child after observing the failure.
        if alive == 0 { kill(child, SIGKILL); launchedChild?.waitUntilExit() }
        XCTAssertEqual(alive, -1, "A read refusal must stop the child before returning")
        XCTAssertEqual(waited, -1, "The helper must reap the child")
        XCTAssertEqual(waitError, ECHILD)
    }

    func testCreditsProcessPreservesCallerConfiguration() throws {
        let process = Process()
        let executable = URL(fileURLWithPath: "/usr/bin/python3")
        let arguments = ["-c", "print('DONE')"]
        process.executableURL = executable
        process.arguments = arguments
        let result = try runCreditsProcess(process)
        XCTAssertEqual(result.status, 0, result.error)
        XCTAssertEqual(process.executableURL, executable)
        XCTAssertEqual(process.arguments, arguments)
        XCTAssertEqual(process.processIdentifier, 0, "Only the helper's wrapper should launch")
    }

    func testCreditsProcessReusesCallerFixtureForDiagnostics() throws {
        try withFixture { root in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", "import sys; sys.stderr.write('fixture diagnostic')"]
            let result = try runCreditsProcess(process, fixtureRoot: root)
            XCTAssertEqual(result.status, 0, result.error)
            XCTAssertEqual(try fileService.readFile(at: root + "/stderr.txt"), "fixture diagnostic")
        }
    }

    func testCreditsNonUTF8DiagnosticsKeepStatusAndOutput() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import os; os.write(2,b'bad\\xffbytes'); os.write(1,b'DONE'); raise SystemExit(7)"]
        let result = try XCTUnwrap(try? runCreditsProcess(process), "Diagnostic decoding must preserve a completed result")
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.output, "DONE")
        XCTAssertEqual(result.error, "bad\u{FFFD}bytes")
    }

    func testCreditsMissingDiagnosticsKeepStatusAndOutput() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import os; os.write(1,b'DONE'); raise SystemExit(7)"]
        let result = try XCTUnwrap(try? runCreditsProcess(process, readStdout: { launched, handle in
            let data = try handle.readToEnd()
            let path = try XCTUnwrap(launched.arguments?[3])
            try self.fileService.deleteFile(at: path)
            return data
        }), "A missing diagnostic file must preserve a completed result")
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.output, "DONE")
        XCTAssertFalse(result.error.isEmpty)
    }

    func testFixtureNoticeCacheNeverFillsCanonicalCache() throws {
        try withFixture { root in
            let count = canonicalNoticeCacheCount
            let path = root + "/source.md"
            try fileService.writeFile(at: path, content: "```text\n" + UUID().uuidString + "\n```\n")
            _ = try loadNotices(at: path, cache: NoticeFileCache())
            XCTAssertEqual(canonicalNoticeCacheCount, count, "Fixture caches must stay separate from canonical notices")
        }
    }
}
