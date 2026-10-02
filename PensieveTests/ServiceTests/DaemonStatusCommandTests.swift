import XCTest
@testable import Pensieve

final class DaemonStatusCommandTests: XCTestCase {
    private let timestamp = "2026-07-16T19:00:00Z"

    func testRenderSyncedStatusIncludesAgeAndExitZero() throws {
        let rendered = DaemonCLI.renderStatus(
            data: fixtureData(result: "synced", detail: "upToDate"),
            path: "/status/daemon-status.json",
            json: false,
            now: try date(secondsAfterTimestamp: 240)
        )

        XCTAssertFalse(rendered.isError)
        XCTAssertEqual(rendered.exitCode, 0)
        XCTAssertTrue(rendered.output.contains("synced upToDate"))
        XCTAssertTrue(rendered.output.contains("(4m ago)"))
        XCTAssertTrue(rendered.output.hasSuffix("\n"))
    }

    func testRenderSkippedStatusExitsZero() throws {
        let rendered = DaemonCLI.renderStatus(
            data: fixtureData(result: "skipped", detail: "noRemote"),
            path: "/status/daemon-status.json",
            json: false,
            now: try date(secondsAfterTimestamp: 60)
        )

        XCTAssertFalse(rendered.isError)
        XCTAssertEqual(rendered.exitCode, 0)
        XCTAssertTrue(rendered.output.contains("skipped noRemote"))
    }

    func testRenderFailedStatusExitsOne() throws {
        let rendered = DaemonCLI.renderStatus(
            data: fixtureData(result: "failed", detail: "authentication"),
            path: "/status/daemon-status.json",
            json: false,
            now: try date(secondsAfterTimestamp: 60)
        )

        XCTAssertFalse(rendered.isError)
        XCTAssertEqual(rendered.exitCode, 1)
        XCTAssertTrue(rendered.output.contains("failed authentication"))
    }

    func testRenderMissingDataExitsTwoAndMentionsPath() {
        let rendered = DaemonCLI.renderStatus(
            data: nil,
            path: "/missing/daemon-status.json",
            json: false,
            now: Date()
        )

        XCTAssertTrue(rendered.isError)
        XCTAssertEqual(rendered.exitCode, 2)
        XCTAssertTrue(rendered.output.contains("/missing/daemon-status.json"))
        XCTAssertTrue(rendered.output.hasSuffix("\n"))
    }

    func testRenderCorruptDataExitsTwoAndMentionsPath() {
        let rendered = DaemonCLI.renderStatus(
            data: Data("not json".utf8),
            path: "/corrupt/daemon-status.json",
            json: false,
            now: Date()
        )

        XCTAssertTrue(rendered.isError)
        XCTAssertEqual(rendered.exitCode, 2)
        XCTAssertTrue(rendered.output.contains("/corrupt/daemon-status.json"))
        XCTAssertTrue(rendered.output.hasSuffix("\n"))
    }

    func testRenderNonUTF8DataExitsTwoEvenWhenJSONDecodable() throws {
        // JSONDecoder auto-detects UTF-16, but the CLIOutcome String seam can only carry UTF-8 —
        // a decodable non-UTF-8 file must fail loud as unreadable (matching log's strict-UTF-8
        // contract), never silently emit empty --json output with exit 0.
        let utf16Data = try XCTUnwrap(
            "{\"timestamp\":\"\(timestamp)\",\"result\":\"skipped\",\"detail\":\"noRemote\"}"
                .data(using: .utf16)
        )
        XCTAssertNil(String(data: utf16Data, encoding: .utf8))

        for json in [false, true] {
            let rendered = DaemonCLI.renderStatus(
                data: utf16Data,
                path: "/status/daemon-status.json",
                json: json,
                now: try date(secondsAfterTimestamp: 60)
            )
            XCTAssertTrue(rendered.isError)
            XCTAssertEqual(rendered.exitCode, 2)
            XCTAssertTrue(rendered.output.contains("unreadable daemon status at /status/daemon-status.json"))
        }
    }

    func testRenderJSONReturnsExactSkippedBytesWithHumanExitCode() throws {
        let data = fixtureData(result: "skipped", detail: "noRemote")
        let human = DaemonCLI.renderStatus(
            data: data,
            path: "/status/daemon-status.json",
            json: false,
            now: try date(secondsAfterTimestamp: 60)
        )
        let json = DaemonCLI.renderStatus(
            data: data,
            path: "/status/daemon-status.json",
            json: true,
            now: try date(secondsAfterTimestamp: 60)
        )

        XCTAssertFalse(json.isError)
        XCTAssertEqual(json.exitCode, human.exitCode)
        XCTAssertEqual(json.output, String(data: data, encoding: .utf8))
        XCTAssertFalse(json.output.hasSuffix("\n"))
    }

    func testRenderJSONReturnsExactFailedBytesWithHumanExitCode() throws {
        let data = fixtureData(result: "failed", detail: "authentication")
        let human = DaemonCLI.renderStatus(
            data: data,
            path: "/status/daemon-status.json",
            json: false,
            now: try date(secondsAfterTimestamp: 60)
        )
        let json = DaemonCLI.renderStatus(
            data: data,
            path: "/status/daemon-status.json",
            json: true,
            now: try date(secondsAfterTimestamp: 60)
        )

        XCTAssertFalse(json.isError)
        XCTAssertEqual(json.exitCode, human.exitCode)
        XCTAssertEqual(json.exitCode, 1)
        XCTAssertEqual(json.output, String(data: data, encoding: .utf8))
        XCTAssertFalse(json.output.hasSuffix("\n"))
    }

    func testRenderStaleStatusAppendsSuffixWithoutChangingExit() throws {
        let rendered = DaemonCLI.renderStatus(
            data: fixtureData(result: "synced", detail: "upToDate"),
            path: "/status/daemon-status.json",
            json: false,
            now: try date(secondsAfterTimestamp: 2_000)
        )

        XCTAssertFalse(rendered.isError)
        XCTAssertEqual(rendered.exitCode, 0)
        XCTAssertTrue(rendered.output.contains("— stale: daemon may be disabled or the Mac was asleep"))
    }

    func testRenderFutureTimestampOmitsAge() throws {
        let rendered = DaemonCLI.renderStatus(
            data: fixtureData(result: "synced", detail: "upToDate"),
            path: "/status/daemon-status.json",
            json: false,
            now: try date(secondsAfterTimestamp: -1)
        )

        XCTAssertFalse(rendered.isError)
        XCTAssertEqual(rendered.exitCode, 0)
        XCTAssertFalse(rendered.output.contains(" ago)"))
        XCTAssertTrue(rendered.output.contains("last cycle \(timestamp): synced upToDate"))
    }

    func testRenderUnknownFutureCategoryPrintsAndExitsZero() throws {
        let rendered = DaemonCLI.renderStatus(
            data: fixtureData(result: "paused", detail: "manual"),
            path: "/status/daemon-status.json",
            json: false,
            now: try date(secondsAfterTimestamp: 60)
        )

        XCTAssertFalse(rendered.isError)
        XCTAssertEqual(rendered.exitCode, 0)
        XCTAssertTrue(rendered.output.contains("paused manual"))
    }

    func testExecuteStatusReadsSelectedAppSupportAndDoesNotRunCycle() throws {
        let defaultData = fixtureData(result: "synced", detail: "upToDate")
        let overrideData = fixtureData(result: "failed", detail: "authentication")
        let now = try date(secondsAfterTimestamp: 240)
        var readPaths: [String] = []
        var runCycleCalls = 0

        let defaultOutcome = DaemonCLI.execute(
            ["status"],
            appSupport: "/default",
            readFile: { path in
                readPaths.append(path)
                return defaultData
            },
            runCycle: {
                runCycleCalls += 1
                return .synced(changed: false)
            },
            now: { now }
        )
        let overrideOutcome = DaemonCLI.execute(
            ["status", "--app-support", "/override", "--json"],
            appSupport: "/default",
            readFile: { path in
                readPaths.append(path)
                return overrideData
            },
            runCycle: {
                runCycleCalls += 1
                return .synced(changed: false)
            },
            now: { now }
        )

        XCTAssertEqual(defaultOutcome.exitCode, 0)
        XCTAssertEqual(defaultOutcome.stderr, "")
        XCTAssertTrue(defaultOutcome.stdout.contains("synced upToDate"))
        XCTAssertEqual(overrideOutcome.exitCode, 1)
        XCTAssertEqual(overrideOutcome.stdout, String(data: overrideData, encoding: .utf8))
        XCTAssertEqual(overrideOutcome.stderr, "")
        XCTAssertEqual(readPaths, ["/default/daemon-status.json", "/override/daemon-status.json"])
        XCTAssertEqual(runCycleCalls, 0)
    }

    private func fixtureData(result: String, detail: String) -> Data {
        Data("{\"timestamp\":\"\(timestamp)\",\"result\":\"\(result)\",\"detail\":\"\(detail)\"}".utf8)
    }

    private func date(secondsAfterTimestamp seconds: TimeInterval) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let date = try XCTUnwrap(formatter.date(from: timestamp))
        return date.addingTimeInterval(seconds)
    }
}
