import XCTest
@testable import Pensieve

@MainActor
final class TestTimeoutDiagnosticsTests: XCTestCase {
    private let files = FileService()
    private var directory = ""

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "timeout-diagnostics-" + UUID().uuidString
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
        XCTAssertEqual(reports.count, 2, "Unwritten reports must fall back to stdout")
        XCTAssertEqual(reports.filter { $0.contains("failed-write state") }.count, 1)
        XCTAssertEqual(reports.filter { $0.contains("failed-write threads") }.count, 1)
        XCTAssertTrue(reports.allSatisfy { $0.contains("END TIMEOUT DIAGNOSTIC ") })
        XCTAssertEqual(try files.readFile(at: blocked), "directory creation is blocked")
    }

}
