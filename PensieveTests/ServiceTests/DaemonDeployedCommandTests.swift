import XCTest
@testable import Pensieve

final class DaemonDeployedCommandTests: XCTestCase {
    func testParseDeployedFlagsInAnyOrder() {
        XCTAssertEqual(DaemonCLI.parse(["deployed"]), .deployed(json: false, appSupport: nil))
        XCTAssertEqual(DaemonCLI.parse(["deployed", "--json"]), .deployed(json: true, appSupport: nil))
        XCTAssertEqual(
            DaemonCLI.parse(["deployed", "--app-support", "/state"]),
            .deployed(json: false, appSupport: "/state")
        )
        XCTAssertEqual(
            DaemonCLI.parse(["deployed", "--json", "--app-support", "/state"]),
            .deployed(json: true, appSupport: "/state")
        )
        XCTAssertEqual(
            DaemonCLI.parse(["deployed", "--app-support", "/state", "--json"]),
            .deployed(json: true, appSupport: "/state")
        )
    }

    func testParseDeployedRejectsUnknownFlagAndMissingAppSupportValue() {
        assertUsageError(DaemonCLI.parse(["deployed", "--bogus"]))
        assertUsageError(DaemonCLI.parse(["deployed", "--app-support"]))
    }

    func testRenderHumanListsRecordsSortedByArtifactPathWithScopes() {
        let rendered = DaemonCLI.renderDeployed(
            data: deployStateData(
                records: [
                    recordJSON(
                        slug: "zeta",
                        platform: "cursor",
                        scope: "user",
                        projectIdentityKey: nil,
                        artifactPath: "/tmp/zeta.mdc"
                    ),
                    recordJSON(
                        slug: "alpha",
                        platform: "claudeCode",
                        scope: "project",
                        projectIdentityKey: "github.com/acme/repo",
                        artifactPath: "/tmp/project/.claude/skills/alpha"
                    )
                ]
            ),
            path: "/state/deploy-state.json",
            json: false
        )

        XCTAssertFalse(rendered.isError)
        XCTAssertEqual(rendered.exitCode, 0)
        XCTAssertEqual(
            rendered.output,
            "alpha\tclaudeCode\tproject:github.com/acme/repo\t/tmp/project/.claude/skills/alpha\n"
                + "zeta\tcursor\tuser\t/tmp/zeta.mdc\n"
        )
    }

    func testRenderKeylessProjectNamesCheckoutPathAndPreservesJSON() throws {
        let data = deployStateData(records: [recordJSON(slug: "alpha", platform: "codex", scope: "project",
            projectIdentityKey: nil, artifactPath: "/checkout/agents/alpha.md")])
        let human = DaemonCLI.renderDeployed(data: data, path: "/state/deploy-state.json", json: false)
        XCTAssertFalse(human.isError)
        XCTAssertEqual(human.exitCode, 0)
        XCTAssertEqual(human.output, "alpha\tcodex\tproject:/checkout\t/checkout/agents/alpha.md\n")
        let json = DaemonCLI.renderDeployed(data: data, path: "/state/deploy-state.json", json: true)
        XCTAssertEqual(Data(json.output.utf8), data)
    }

    func testRenderEmptyHumanStateSaysNoDeploymentsRecorded() {
        let rendered = DaemonCLI.renderDeployed(
            data: Data(#"{"records":[],"schema_version":1}"#.utf8),
            path: "/state/deploy-state.json",
            json: false
        )

        XCTAssertFalse(rendered.isError)
        XCTAssertEqual(rendered.output, "no deployments recorded\n")
        XCTAssertEqual(rendered.exitCode, 0)
    }

    func testRenderJSONReturnsExactBytesWithoutAddingNewline() throws {
        let data = deployStateData(
            records: [
                recordJSON(
                    slug: "foo",
                    platform: "cursor",
                    scope: "user",
                    projectIdentityKey: nil,
                    artifactPath: "/tmp/foo.mdc"
                )
            ]
        )

        let rendered = DaemonCLI.renderDeployed(data: data, path: "/state/deploy-state.json", json: true)

        XCTAssertFalse(rendered.isError)
        XCTAssertEqual(rendered.exitCode, 0)
        XCTAssertEqual(Data(rendered.output.utf8), data)
        XCTAssertFalse(rendered.output.hasSuffix("\n"))
    }

    func testRenderMissingDataExitsTwoAndMentionsPath() {
        let rendered = DaemonCLI.renderDeployed(data: nil, path: "/missing/deploy-state.json", json: false)

        XCTAssertTrue(rendered.isError)
        XCTAssertEqual(rendered.exitCode, 2)
        XCTAssertTrue(rendered.output.contains("no deploy state at /missing/deploy-state.json"))
        XCTAssertTrue(rendered.output.hasSuffix("\n"))
    }

    func testRenderCorruptDataExitsTwoAndMentionsPath() {
        let rendered = DaemonCLI.renderDeployed(
            data: Data("not json".utf8),
            path: "/corrupt/deploy-state.json",
            json: false
        )

        XCTAssertTrue(rendered.isError)
        XCTAssertEqual(rendered.exitCode, 2)
        XCTAssertEqual(rendered.output, "unreadable deploy state at /corrupt/deploy-state.json\n")
    }

    func testRenderNonUTF8DataExitsTwoEvenWhenJSONDecodable() throws {
        let utf16Data = try XCTUnwrap(
            #"{"records":[],"schema_version":1}"#.data(using: .utf16)
        )
        XCTAssertNil(String(data: utf16Data, encoding: .utf8))

        for json in [false, true] {
            let rendered = DaemonCLI.renderDeployed(
                data: utf16Data,
                path: "/state/deploy-state.json",
                json: json
            )
            XCTAssertTrue(rendered.isError)
            XCTAssertEqual(rendered.exitCode, 2)
            XCTAssertEqual(rendered.output, "unreadable deploy state at /state/deploy-state.json\n")
        }
    }

    func testRenderNewerSchemaExitsTwoAndMentionsPath() {
        let rendered = DaemonCLI.renderDeployed(
            data: Data(#"{"records":[],"schema_version":2}"#.utf8),
            path: "/future/deploy-state.json",
            json: false
        )

        XCTAssertTrue(rendered.isError)
        XCTAssertEqual(rendered.exitCode, 2)
        XCTAssertEqual(rendered.output, "unreadable deploy state at /future/deploy-state.json\n")
    }

    func testExecuteDeployedReadsSelectedAppSupportAndDoesNotRunCycle() {
        var readPaths: [String] = []
        var runCycleCalls = 0
        let outcome = DaemonCLI.execute(
            ["deployed", "--app-support", "/state", "--json"],
            appSupport: "/default",
            readFile: { path in
                readPaths.append(path)
                return Data(#"{"records":[],"schema_version":1}"#.utf8)
            },
            runCycle: {
                runCycleCalls += 1
                return .synced(changed: false)
            },
            now: Date.init
        )

        XCTAssertEqual(outcome.stdout, #"{"records":[],"schema_version":1}"#)
        XCTAssertEqual(outcome.stderr, "")
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertEqual(readPaths, ["/state/deploy-state.json"])
        XCTAssertEqual(runCycleCalls, 0)
    }

    func testExecuteDeployedUnknownFlagExitsSixtyFourWithoutReadOrRunCycle() {
        var readPaths: [String] = []
        var runCycleCalls = 0
        let outcome = DaemonCLI.execute(
            ["deployed", "--nope"],
            appSupport: "/default",
            readFile: { path in
                readPaths.append(path)
                return nil
            },
            runCycle: {
                runCycleCalls += 1
                return .synced(changed: false)
            },
            now: Date.init
        )

        XCTAssertEqual(outcome.stdout, "")
        XCTAssertTrue(outcome.stderr.contains("unknown flag for deployed: --nope"))
        XCTAssertEqual(outcome.exitCode, 64)
        XCTAssertEqual(readPaths, [])
        XCTAssertEqual(runCycleCalls, 0)
    }

    private func deployStateData(records: [String]) -> Data {
        Data("{\"records\":[\(records.joined(separator: ","))],\"schema_version\":1}".utf8)
    }

    private func recordJSON(
        slug: String,
        platform: String,
        scope: String,
        projectIdentityKey: String?,
        artifactPath: String
    ) -> String {
        let projectFragment = projectIdentityKey.map { ",\"project_identity_key\":\"\($0)\"" } ?? ""
        return "{\"artifact_path\":\"\(artifactPath)\",\"platform\":\"\(platform)\","
            + "\"recorded_at\":\"2026-07-17T00:00:00Z\",\"scope\":\"\(scope)\","
            + "\"slug\":\"\(slug)\"\(projectFragment)}"
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
