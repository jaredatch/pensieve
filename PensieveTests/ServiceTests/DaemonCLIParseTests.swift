import XCTest
@testable import Pensieve

final class DaemonCLIParseTests: XCTestCase {
    func testParseBareIsUsageError() {
        XCTAssertEqual(DaemonCLI.parse([]), .usageError("no command given; use `run` to sync"))
    }

    func testParseRunRunsCycle() {
        XCTAssertEqual(DaemonCLI.parse(["run"]), .runCycle)
    }

    func testParseRunWithTrailingArgumentIsUsageError() {
        assertUsageError(DaemonCLI.parse(["run", "extra"]))
    }

    func testParseVersionAnywhereWins() {
        XCTAssertEqual(DaemonCLI.parse(["--version"]), .version)
        XCTAssertEqual(DaemonCLI.parse(["status", "--json", "--version"]), .version)
    }

    func testParseHelpForms() {
        XCTAssertEqual(DaemonCLI.parse(["help"]), .help)
        XCTAssertEqual(DaemonCLI.parse(["--help"]), .help)
        XCTAssertEqual(DaemonCLI.parse(["-h"]), .help)
    }

    func testParseUnknownCommandIsUsageError() {
        assertUsageError(DaemonCLI.parse(["definitely-not-a-command"]))
    }

    func testParseStatusFlagsInAnyOrder() {
        XCTAssertEqual(DaemonCLI.parse(["status", "--json"]), .status(json: true, appSupport: nil))
        XCTAssertEqual(
            DaemonCLI.parse(["status", "--app-support", "/x"]),
            .status(json: false, appSupport: "/x")
        )
        XCTAssertEqual(
            DaemonCLI.parse(["status", "--json", "--app-support", "/x"]),
            .status(json: true, appSupport: "/x")
        )
        XCTAssertEqual(
            DaemonCLI.parse(["status", "--app-support", "/x", "--json"]),
            .status(json: true, appSupport: "/x")
        )
    }

    func testParseStatusRejectsUnknownFlagAndMissingAppSupportValue() {
        assertUsageError(DaemonCLI.parse(["status", "--bogus"]))
        assertUsageError(DaemonCLI.parse(["status", "--app-support"]))
    }

    func testParseLogFlags() {
        XCTAssertEqual(DaemonCLI.parse(["log"]), .log(lines: DaemonCLI.defaultLogLines, appSupport: nil))
        XCTAssertEqual(DaemonCLI.parse(["log", "--lines", "5"]), .log(lines: 5, appSupport: nil))
        XCTAssertEqual(
            DaemonCLI.parse(["log", "--app-support", "/x", "--lines", "5"]),
            .log(lines: 5, appSupport: "/x")
        )
        XCTAssertEqual(
            DaemonCLI.parse(["log", "--lines", "5", "--app-support", "/x"]),
            .log(lines: 5, appSupport: "/x")
        )
    }

    func testParseLogRejectsInvalidLinesAndMissingAppSupportValue() {
        assertUsageError(DaemonCLI.parse(["log", "--lines", "0"]))
        assertUsageError(DaemonCLI.parse(["log", "--lines", "x"]))
        assertUsageError(DaemonCLI.parse(["log", "--app-support"]))
        assertUsageError(DaemonCLI.parse(["log", "--bogus"]))
    }

    func testExecuteRunCycleMapsSyncedSkippedAndFailedResults() {
        assertRunOutcome(.synced(changed: false), stdout: "pensieve-daemon synced upToDate\n", exitCode: 0)
        assertRunOutcome(.synced(changed: true), stdout: "pensieve-daemon synced fastForwarded\n", exitCode: 0)
        assertRunOutcome(.skipped(.locked), stdout: "pensieve-daemon skipped locked\n", exitCode: 0)
        assertRunOutcome(.failed(.authentication), stdout: "pensieve-daemon failed authentication\n", exitCode: 1)
    }

    func testExecuteBareWritesUsageAndDoesNotRunCycle() {
        var calls = 0

        let outcome = DaemonCLI.execute(
            [],
            appSupport: "/unused",
            readFile: { _ in nil },
            runCycle: {
                calls += 1
                return .synced(changed: false)
            },
            now: Date.init
        )

        XCTAssertEqual(calls, 0, "a bare invocation must not run a sync cycle")
        XCTAssertEqual(outcome.exitCode, 64)
        XCTAssertEqual(outcome.stdout, "")
        XCTAssertTrue(
            outcome.stderr.hasPrefix("no command given; use `run` to sync\n\n"),
            "stderr must start with the no-command message"
        )
        XCTAssertTrue(outcome.stderr.contains(DaemonCLI.usage()), "stderr must include the usage text")
    }

    func testExecuteUsageErrorWritesStderrAndDoesNotRunCycle() {
        var calls = 0

        let outcome = DaemonCLI.execute(
            ["definitely-not-a-command"],
            appSupport: "/unused",
            readFile: { _ in nil },
            runCycle: {
                calls += 1
                return .synced(changed: false)
            },
            now: Date.init
        )

        XCTAssertEqual(outcome.stdout, "")
        XCTAssertTrue(outcome.stderr.contains("unknown command: definitely-not-a-command"))
        XCTAssertTrue(outcome.stderr.localizedCaseInsensitiveContains("usage"))
        XCTAssertEqual(outcome.exitCode, 64)
        XCTAssertEqual(calls, 0)
    }

    func testExecuteVersionAndHelpDoNotRunCycle() {
        // Read-only commands must never invoke the sync cycle (they construct no SyncDaemon,
        // touch no Keychain/git) — count calls across these commands and require zero.
        var runCycleCalls = 0
        let countingRunCycle: () -> DaemonCycleResult = {
            runCycleCalls += 1
            return .failed(.gitError)
        }

        XCTAssertEqual(
            DaemonCLI.execute(
                ["--version"],
                appSupport: "/unused",
                readFile: { _ in nil },
                runCycle: countingRunCycle,
                now: Date.init
            ),
            CLIOutcome(stdout: "pensieve-daemon \(DaemonCLI.daemonVersion)\n", stderr: "", exitCode: 0)
        )

        let help = DaemonCLI.execute(
            ["help"],
            appSupport: "/unused",
            readFile: { _ in nil },
            runCycle: countingRunCycle,
            now: Date.init
        )
        XCTAssertEqual(help.stdout, DaemonCLI.usage())
        XCTAssertEqual(help.stderr, "")
        XCTAssertEqual(help.exitCode, 0)

        XCTAssertEqual(runCycleCalls, 0)
    }

    func testRunHelpNamesResidentAppAsPrimary() {
        let help = DaemonCLI.usage()

        XCTAssertTrue(help.contains("The Pensieve app is the primary sync actor"))
        XCTAssertTrue(help.contains("degraded SSH"))
    }

    func testUsageListsRunAndOmitsBareInvocation() {
        let help = DaemonCLI.usage()

        XCTAssertTrue(help.contains("  pensieve-daemon run "))
        XCTAssertNil(help.range(of: #"(?m)^ +pensieve-daemon {2,}"#, options: .regularExpression))
    }

    private func assertRunOutcome(_ result: DaemonCycleResult, stdout: String, exitCode: Int32) {
        var calls = 0
        let outcome = DaemonCLI.execute(
            ["run"],
            appSupport: "/unused",
            readFile: { _ in nil },
            runCycle: {
                calls += 1
                return result
            },
            now: Date.init
        )

        XCTAssertEqual(outcome, CLIOutcome(stdout: stdout, stderr: "", exitCode: exitCode))
        XCTAssertEqual(calls, 1, "run must invoke exactly one sync cycle")
    }

    private func assertUsageError(
        _ command: DaemonCommand,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .usageError = command else {
            XCTFail("expected usage error, got \(command)", file: file, line: line)
            return
        }
    }
}
