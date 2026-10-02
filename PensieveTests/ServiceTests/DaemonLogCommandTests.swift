import XCTest
@testable import Pensieve

final class DaemonLogCommandTests: XCTestCase {
    func testRenderCurrentLogTailsLastLinesWithTrailingNewline() {
        let rendered = DaemonCLI.renderLog(current: "a\nb\nc\n", rotated: nil, lines: 2)

        XCTAssertFalse(rendered.isError)
        XCTAssertEqual(rendered.exitCode, 0)
        XCTAssertEqual(rendered.output, "b\nc\n")
    }

    func testRenderTailSpansRotationBoundary() {
        let rendered = DaemonCLI.renderLog(current: "c1\n", rotated: "r1\nr2\n", lines: 2)

        XCTAssertFalse(rendered.isError)
        XCTAssertEqual(rendered.exitCode, 0)
        XCTAssertEqual(rendered.output, "r2\nc1\n")
    }

    func testRenderLinesLargerThanAvailableReturnsAllWithoutPadding() {
        let rendered = DaemonCLI.renderLog(current: "c1\n", rotated: "r1\n", lines: 20)

        XCTAssertFalse(rendered.isError)
        XCTAssertEqual(rendered.exitCode, 0)
        XCTAssertEqual(rendered.output, "r1\nc1\n")
    }

    func testRenderRotatedOnlyLogExitsZero() {
        let rendered = DaemonCLI.renderLog(current: nil, rotated: "r1\nr2\n", lines: 1)

        XCTAssertFalse(rendered.isError)
        XCTAssertEqual(rendered.exitCode, 0)
        XCTAssertEqual(rendered.output, "r2\n")
    }

    func testRenderBothMissingExitsTwo() {
        let rendered = DaemonCLI.renderLog(current: nil, rotated: nil, lines: 20)

        XCTAssertTrue(rendered.isError)
        XCTAssertEqual(rendered.exitCode, 2)
        XCTAssertTrue(rendered.output.contains("no daemon log at daemon.log"))
        XCTAssertTrue(rendered.output.hasSuffix("\n"))
    }

    func testRenderPresentEmptyCurrentReturnsEmptyStdout() {
        let rendered = DaemonCLI.renderLog(current: "", rotated: nil, lines: 20)

        XCTAssertFalse(rendered.isError)
        XCTAssertEqual(rendered.exitCode, 0)
        XCTAssertEqual(rendered.output, "")
    }

    func testRenderPreservesLineContentVerbatim() {
        let rendered = DaemonCLI.renderLog(
            current: "  leading space\ntrailing space  \n\tindented\n",
            rotated: nil,
            lines: 3
        )

        XCTAssertFalse(rendered.isError)
        XCTAssertEqual(rendered.exitCode, 0)
        XCTAssertEqual(rendered.output, "  leading space\ntrailing space  \n\tindented\n")
    }

    func testExecuteLogReadsCurrentAndRotatedWithoutRunningCycle() {
        var readPaths: [String] = []
        var runCycleCalls = 0
        let outcome = DaemonCLI.execute(
            ["log", "--app-support", "/logs", "--lines", "2"],
            appSupport: "/default",
            readFile: { path in
                readPaths.append(path)
                switch path {
                case "/logs/daemon.log":
                    return Data("c1\n".utf8)
                case "/logs/daemon.log.1":
                    return Data("r1\nr2\n".utf8)
                default:
                    return nil
                }
            },
            runCycle: {
                runCycleCalls += 1
                return .synced(changed: false)
            },
            now: Date.init
        )

        XCTAssertEqual(outcome.stdout, "r2\nc1\n")
        XCTAssertEqual(outcome.stderr, "")
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertEqual(readPaths, ["/logs/daemon.log", "/logs/daemon.log.1"])
        XCTAssertEqual(runCycleCalls, 0)
    }

    func testExecuteLogBothMissingMentionsCurrentPathAndDoesNotRunCycle() {
        var runCycleCalls = 0
        let outcome = DaemonCLI.execute(
            ["log", "--app-support", "/empty"],
            appSupport: "/default",
            readFile: { _ in nil },
            runCycle: {
                runCycleCalls += 1
                return .synced(changed: false)
            },
            now: Date.init
        )

        XCTAssertEqual(outcome.stdout, "")
        XCTAssertEqual(outcome.stderr, "no daemon log at /empty/daemon.log\n")
        XCTAssertEqual(outcome.exitCode, 2)
        XCTAssertEqual(runCycleCalls, 0)
    }

    func testExecuteLogInvalidUTF8CurrentExitsTwoAndMentionsPath() {
        var runCycleCalls = 0
        let outcome = DaemonCLI.execute(
            ["log", "--app-support", "/logs"],
            appSupport: "/default",
            readFile: { path in
                path == "/logs/daemon.log" ? Data([0xff, 0xfe]) : nil
            },
            runCycle: {
                runCycleCalls += 1
                return .synced(changed: false)
            },
            now: Date.init
        )

        XCTAssertEqual(outcome.stdout, "")
        XCTAssertEqual(outcome.stderr, "unreadable daemon log at /logs/daemon.log\n")
        XCTAssertEqual(outcome.exitCode, 2)
        XCTAssertEqual(runCycleCalls, 0)
    }

    func testExecuteLogInvalidUTF8RotatedExitsTwoAndMentionsPath() {
        var runCycleCalls = 0
        let outcome = DaemonCLI.execute(
            ["log", "--app-support", "/logs"],
            appSupport: "/default",
            readFile: { path in
                switch path {
                case "/logs/daemon.log":
                    return Data("c1\n".utf8)
                case "/logs/daemon.log.1":
                    return Data([0xff, 0xfe])
                default:
                    return nil
                }
            },
            runCycle: {
                runCycleCalls += 1
                return .synced(changed: false)
            },
            now: Date.init
        )

        XCTAssertEqual(outcome.stdout, "")
        XCTAssertEqual(outcome.stderr, "unreadable daemon log at /logs/daemon.log.1\n")
        XCTAssertEqual(outcome.exitCode, 2)
        XCTAssertEqual(runCycleCalls, 0)
    }
}
