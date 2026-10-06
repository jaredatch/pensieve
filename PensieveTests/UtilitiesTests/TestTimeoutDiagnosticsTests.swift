import Darwin
import XCTest
@testable import Pensieve

@MainActor
final class TestTimeoutDiagnosticsTests: XCTestCase {
    private let files = FileService()
    private var directory = ""

    override func setUpWithError() throws {
        directory = TestTemporaryDirectory.path + "timeout-diagnostics-" + UUID().uuidString
        try files.createDirectory(at: directory)
    }

    override func tearDownWithError() throws {
        try files.deleteDirectory(at: directory)
    }

    func testWrapperReportsUseFilesWithoutEchoingBufferedHostOutput() throws {
        var output: [String] = []
        let observer = TestTimeoutDiagnostics(environment: ["PENSIEVE_TEST_DIAGNOSTICS_DIR": directory],
                                              output: { output.append($0) })
        observer.recordSnapshot("timeout state sentinel", threadSample: "timeout threads sentinel")
        observer.testCase(self, didRecord: XCTIssue(type: .assertionFailure, compactDescription: "timeout probe"))

        XCTAssertEqual(output, [], "The wrapper relay owns stdout; Xcode must not echo the same reports later")
        let reports = try files.listDirectory(at: directory)
        XCTAssertEqual(reports.count, 2)
        let state = try XCTUnwrap(reports.first { $0.hasSuffix("-state.txt") })
        let threads = try XCTUnwrap(reports.first { $0.hasSuffix("-threads.txt") })
        XCTAssertEqual(state.replacingOccurrences(of: "-state.txt", with: ""),
                       threads.replacingOccurrences(of: "-threads.txt", with: ""))
        XCTAssertTrue(try files.readFile(at: directory + "/" + state).contains("timeout state sentinel"))
        XCTAssertEqual(try files.readFile(at: directory + "/" + threads), "timeout threads sentinel")
    }

    func testStandaloneReportsStillPrintEachFileOnce() throws {
        var output: [String] = []
        let observer = TestTimeoutDiagnostics(environment: [:], fallbackDirectory: directory,
                                              output: { output.append($0) })
        observer.recordSnapshot("standalone state", threadSample: "standalone threads")
        observer.testCase(self, didRecord: XCTIssue(type: .assertionFailure, compactDescription: "timeout probe"))

        let reports = try files.listDirectory(at: directory)
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(output.count, 2)
        for report in reports {
            let printed = try XCTUnwrap(output.first { $0.hasPrefix("BEGIN TIMEOUT DIAGNOSTIC " + report + "\n") })
            XCTAssertTrue(printed.hasSuffix("\nEND TIMEOUT DIAGNOSTIC " + report))
            XCTAssertTrue(printed.contains(try files.readFile(at: directory + "/" + report)))
        }
    }
    func testWrapperPrintsReportsWhoseFilesCannotBeWritten() throws {
        let blocked = directory + "/blocked"
        try files.writeFile(at: blocked, content: "directory creation is blocked")
        var output: [String] = []
        let observer = TestTimeoutDiagnostics(environment: ["PENSIEVE_TEST_DIAGNOSTICS_DIR": blocked],
                                              output: { output.append($0) })
        observer.recordSnapshot("failed-write state", threadSample: "failed-write threads")
        observer.testCase(self, didRecord: XCTIssue(type: .assertionFailure, compactDescription: "timeout probe"))

        let reports = output.filter { $0.hasPrefix("BEGIN TIMEOUT DIAGNOSTIC ") }
        XCTAssertEqual(reports.count, 2, "Unwritten reports must reach the wrapper")
        XCTAssertEqual(reports.filter { $0.contains("failed-write state") }.count, 1)
        XCTAssertEqual(reports.filter { $0.contains("failed-write threads") }.count, 1)
        XCTAssertTrue(reports.allSatisfy { $0.contains("END TIMEOUT DIAGNOSTIC ") })
        XCTAssertEqual(try files.readFile(at: blocked), "directory creation is blocked")
    }

    func testPartialWritePrintsOnlyMissingThreadsReport() throws {
        var output: [String] = []
        let observer = TestTimeoutDiagnostics(environment: ["PENSIEVE_TEST_DIAGNOSTICS_DIR": directory],
                                              output: { output.append($0) }, writeReport: { path, content in
            if path.hasSuffix("-threads.txt") { throw CocoaError(.fileWriteUnknown) }
            try self.files.writeFile(at: path, content: content)
        })
        observer.recordSnapshot("partial state", threadSample: "partial threads")
        observer.testCase(self, didRecord: XCTIssue(type: .assertionFailure, compactDescription: "timeout probe"))
        let saved = try files.listDirectory(at: directory)
        XCTAssertEqual(saved.count, 1)
        XCTAssertTrue(try XCTUnwrap(saved.first).hasSuffix("-state.txt"))
        let reports = output.filter { $0.hasPrefix("BEGIN TIMEOUT DIAGNOSTIC ") }
        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(try XCTUnwrap(reports.first).contains("partial threads"))
        XCTAssertFalse(reports.contains { $0.contains("partial state") })
    }

    func testDefaultFailedWriteReportsReachUnbufferedStderr() throws {
        let blocked = directory + "/blocked"
        try files.writeFile(at: blocked, content: "blocked")
        let output = try captureStandardError { _ in
            let observer = TestTimeoutDiagnostics(environment: ["PENSIEVE_TEST_DIAGNOSTICS_DIR": blocked])
            observer.recordSnapshot("stderr state sentinel", threadSample: "stderr threads sentinel")
            observer.testCase(self, didRecord: XCTIssue(type: .assertionFailure, compactDescription: "timeout probe"))
        }
        XCTAssertEqual(output.components(separatedBy: "Timeout diagnostics could not write ").count - 1, 2)
        XCTAssertEqual(output.components(separatedBy: "BEGIN TIMEOUT DIAGNOSTIC ").count - 1, 2)
        XCTAssertEqual(output.components(separatedBy: "END TIMEOUT DIAGNOSTIC ").count - 1, 2)
        XCTAssertTrue(output.contains("stderr state sentinel"))
        XCTAssertTrue(output.contains("stderr threads sentinel"))
    }

    func testDefaultPartialWriteFlushesOnlyMissingReportToStderr() throws {
        let output = try captureStandardError { _ in
            let observer = TestTimeoutDiagnostics(environment: ["PENSIEVE_TEST_DIAGNOSTICS_DIR": directory],
                writeReport: { path, content in
                    if path.hasSuffix("-threads.txt") { throw CocoaError(.fileWriteUnknown) }
                    try self.files.writeFile(at: path, content: content)
                })
            observer.recordSnapshot("saved default state", threadSample: "missing default threads")
            observer.testCase(self, didRecord: XCTIssue(type: .assertionFailure, compactDescription: "timeout probe"))
        }
        XCTAssertEqual(output.components(separatedBy: "BEGIN TIMEOUT DIAGNOSTIC ").count - 1, 1)
        XCTAssertEqual(output.components(separatedBy: "END TIMEOUT DIAGNOSTIC ").count - 1, 1)
        XCTAssertTrue(output.contains("missing default threads"))
        XCTAssertFalse(output.contains("saved default state"))
        XCTAssertEqual(try files.listDirectory(at: directory).filter { $0.hasSuffix("-state.txt") }.count, 1)
    }

    func testStandardErrorSinkFlushesEveryWriteBeforeTeardown() throws {
        try captureStandardError { readDescriptor in
            let messages = ["first report " + UUID().uuidString, "second report " + UUID().uuidString]
            for (index, message) in messages.enumerated() {
                fputs("unrelated host stderr\n", stderr)
                _ = fflush(stderr)
                TestTimeoutDiagnostics.writeToStandardError(message)
                let captured = try readDescriptor()
                var remaining = captured[...]
                for expected in messages.prefix(index + 1) {
                    let range = try XCTUnwrap(remaining.range(of: expected + "\n"),
                        "Each write must reach stderr in order before another write or teardown flushes it")
                    remaining = remaining[range.upperBound...]
                }
            }
        }
    }

    @discardableResult
    private func captureStandardError(_ body: (() throws -> String) throws -> Void) throws -> String {
        let path = directory + "/stderr-" + UUID().uuidString + ".txt"
        let descriptor = try FileService.openRegularFile(at: path, creatingWithPermissions: 0o600).descriptor
        defer { close(descriptor) }
        fflush(stderr)
        let saved = dup(STDERR_FILENO)
        XCTAssertGreaterThanOrEqual(saved, 0)
        defer { close(saved) }
        XCTAssertEqual(dup2(descriptor, STDERR_FILENO), STDERR_FILENO)
        // Force buffering so reading before the cleanup flush detects a missing default fflush.
        XCTAssertEqual(setvbuf(stderr, nil, _IOFBF, 65_536), 0)
        defer {
            fflush(stderr)
            _ = dup2(saved, STDERR_FILENO)
            _ = setvbuf(stderr, nil, _IONBF, 0)
        }
        try body { try files.readFile(at: path) }
        return try files.readFile(at: path)
    }
}
