import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class MachineStateServiceTests: XCTestCase {
    private var tempDir = ""
    private var suiteName = ""
    private var defaults: UserDefaults!
    private let fileService = FileService()
    private let machineID = "5A9C2E31-8F04-4D2B-9C61-0B7A43F1D002"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MachineStateServiceTests-\(UUID().uuidString)").path
        try fileService.createDirectory(at: tempDir)
        suiteName = isolatedDefaultsSuite()
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: suiteName)
        if !tempDir.isEmpty { try? fileService.deleteDirectory(at: tempDir) }
    }

    func testStateRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_777_777_777)
        let context = try makeContext()
        let state = try service().compose(machineID: machineID, context: context, publishedAt: date)
        try service().write(state, toRoot: tempDir)
        XCTAssertEqual(service().readAll(fromRoot: tempDir), [state])
        XCTAssertEqual(state.name, "Fixture Host")
        XCTAssertEqual(state.publishedAt, date)
    }

    func testProjectionFromDeployState() throws {
        defaults.set("Named Mac", forKey: MachineDisplayName.defaultsKey)
        let context = try makeContext()
        let project = Project(name: "Pensieve", path: tempDir + "/project")
        project.identityKey = "github.com/jaredatch/pensieve"
        project.identityKind = "git-remote"
        context.insert(project)
        try context.save()

        let realized = DeployState(schemaVersion: 1, records: [
            deployRecord(slug: "pdf-tools", platform: "claudeCode", scope: "user"),
            deployRecord(slug: "swift-conventions", platform: "codex", scope: "project",
                         projectKey: project.identityKey),
            deployRecord(slug: "orphaned-project", platform: "codex", scope: "project",
                         projectKey: "github.com/example/missing")
        ])
        let state = try service(installed: [.codex, .claudeCode], deployState: realized)
            .compose(machineID: machineID, context: context, publishedAt: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(state.name, "Named Mac")
        XCTAssertEqual(state.agents, ["claudeCode", "codex"])
        XCTAssertEqual(state.projects, [MachineStateProject(identityKey: project.identityKey!,
                                                              kind: "git-remote", name: "Pensieve")])
        XCTAssertEqual(state.userDeploys, [MachineStateUserDeploy(slug: "pdf-tools", platform: "claudeCode")])
        XCTAssertEqual(state.projectDeploys, [MachineStateProjectDeploy(
            slug: "swift-conventions", platform: "codex", projectKey: project.identityKey!
        )])
    }

    func testProjectsDeduplicateByIdentity() throws {
        let context = try makeContext()
        let first = Project(name: "Zulu", path: tempDir + "/zulu")
        first.identityKey = "github.com/example/shared"
        first.identityKind = "git-remote"
        let second = Project(name: "Alpha", path: tempDir + "/alpha")
        second.identityKey = first.identityKey
        second.identityKind = "git-remote"
        context.insert(first)
        context.insert(second)
        try context.save()

        let state = try service().compose(
            machineID: machineID, context: context, publishedAt: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(state.projects, [MachineStateProject(
            identityKey: "github.com/example/shared", kind: "git-remote", name: "Alpha"
        )])
    }

    func testNewerSchemaSkipped() throws {
        try writeRaw(id: machineID, content: stateYAML(machineID: machineID, schema: 2))
        XCTAssertTrue(service().readAll(fromRoot: tempDir).isEmpty)
    }

    func testNonPositiveSchemaSkipped() throws {
        try writeRaw(id: machineID, content: stateYAML(machineID: machineID, schema: 0))
        XCTAssertTrue(service().readAll(fromRoot: tempDir).isEmpty)
    }

    func testCorruptSiblingSkipped() throws {
        let context = try makeContext()
        let valid = try service().compose(machineID: machineID, context: context, publishedAt: Date(timeIntervalSince1970: 0))
        try service().write(valid, toRoot: tempDir)
        try writeRaw(id: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", content: "not: [valid")
        XCTAssertEqual(service().readAll(fromRoot: tempDir), [valid])
    }

    func testUnknownKeysTolerated() throws {
        let context = try makeContext()
        let valid = try service().compose(machineID: machineID, context: context, publishedAt: Date(timeIntervalSince1970: 0))
        try service().write(valid, toRoot: tempDir)
        let path = tempDir + "/machines/" + machineID + ".yaml"
        try fileService.writeFile(at: path, content: try fileService.readFile(at: path) + "future_key: value\n")
        XCTAssertEqual(service().readAll(fromRoot: tempDir), [valid])
    }

    func testWriteReadRoundTripIsFixedPoint() throws {
        let empty = MachineState(
            schemaVersion: 1,
            machineID: machineID,
            name: "Empty Mac",
            appVersion: "0.13.0",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            agents: [],
            projects: [],
            userDeploys: [],
            projectDeploys: []
        )
        let populated = MachineState(
            schemaVersion: 1,
            machineID: machineID,
            name: "Renée's \"Studio\" Mac",
            appVersion: "0.13.0",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_100),
            agents: ["claudeCode", "codex"],
            projects: [
                MachineStateProject(
                    identityKey: "github.com/example/project", kind: "git-remote", name: "Project \"Élan\""
                )
            ],
            userDeploys: [MachineStateUserDeploy(slug: "café-skill", platform: "claudeCode")],
            projectDeploys: [MachineStateProjectDeploy(
                slug: "quoted-skill", platform: "codex", projectKey: "github.com/example/project"
            )]
        )

        for (index, state) in [empty, populated].enumerated() {
            let firstRoot = tempDir + "/fixed-point-\(index)-first"
            let secondRoot = tempDir + "/fixed-point-\(index)-second"
            try service().write(state, toRoot: firstRoot)
            let parsed = try XCTUnwrap(service().readAll(fromRoot: firstRoot).first)
            XCTAssertTrue(parsed.contentEquals(state))

            try service().write(parsed, toRoot: secondRoot)
            let relativePath = "/machines/" + machineID + ".yaml"
            XCTAssertEqual(try fileService.readData(at: firstRoot + relativePath),
                           try fileService.readData(at: secondRoot + relativePath))
        }
    }

    func testContentEqualsIgnoresOnlyPublishedAt() {
        let base = contentState()
        let timestampOnly = contentState(publishedAt: Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertTrue(base.contentEquals(timestampOnly))

        let differences = [
            contentState(schemaVersion: 2),
            contentState(machineID: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"),
            contentState(name: "Renamed Mac"),
            contentState(appVersion: "0.14.0"),
            contentState(agents: ["codex"]),
            contentState(projects: []),
            contentState(userDeploys: []),
            contentState(projectDeploys: [])
        ]
        for difference in differences {
            XCTAssertFalse(base.contentEquals(difference))
        }
        XCTAssertEqual(
            Mirror(reflecting: base).children.count,
            9,
            "MachineState gained a stored property; update contentEquals and this field-count pin"
        )
    }

    private func contentState(
        schemaVersion: Int = 1,
        machineID: String? = nil,
        name: String = "Fixture Mac",
        appVersion: String = "0.13.0",
        publishedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        agents: [String] = ["claudeCode"],
        projects: [MachineStateProject]? = nil,
        userDeploys: [MachineStateUserDeploy]? = nil,
        projectDeploys: [MachineStateProjectDeploy]? = nil
    ) -> MachineState {
        let project = MachineStateProject(
            identityKey: "github.com/example/project", kind: "git-remote", name: "Project"
        )
        return MachineState(
            schemaVersion: schemaVersion,
            machineID: machineID ?? self.machineID,
            name: name,
            appVersion: appVersion,
            publishedAt: publishedAt,
            agents: agents,
            projects: projects ?? [project],
            userDeploys: userDeploys ?? [
                MachineStateUserDeploy(slug: "user-skill", platform: "claudeCode")
            ],
            projectDeploys: projectDeploys ?? [
                MachineStateProjectDeploy(
                    slug: "project-skill", platform: "codex", projectKey: project.identityKey
                )
            ]
        )
    }

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private func service(
        installed: [PlatformTarget] = [],
        deployState: DeployState = DeployState(schemaVersion: 1, records: []),
        hostName: String? = "Fixture Host",
        warn: @escaping (String) -> Void = { _ in }
    ) -> MachineStateService {
        MachineStateService(fileService: fileService, agentDetection: FixedMachineDetection(installed: installed),
                            defaults: defaults, deployState: { deployState }, hostName: { hostName },
                            appVersion: { "0.12.0" }, warn: warn)
    }

    private func deployRecord(
        slug: String, platform: String, scope: String, projectKey: String? = nil
    ) -> DeployStateRecord {
        DeployStateRecord(slug: slug, platform: platform, scope: scope, projectIdentityKey: projectKey,
                          artifactPath: "/fixture/" + slug, recordedAt: "2026-08-20T14:05:11Z")
    }

    private func writeRaw(id: String, content: String) throws {
        try fileService.createDirectory(at: tempDir + "/machines")
        try fileService.writeFile(at: tempDir + "/machines/" + id + ".yaml", content: content)
    }
}

extension MachineStateServiceTests {
    private var hostNameExpectations: [(hostName: String?, publishedName: String)] {
        [("Studio", "Studio"), ("  Studio  ", "Studio"), ("", "Mac"), (" \t\n", "Mac"), (nil, "Mac")]
    }

    func testPublishedNameTrimsHostOrUsesMac() throws {
        let context = try makeContext()
        for (hostName, expectedName) in hostNameExpectations {
            let state = try service(hostName: hostName).compose(
                machineID: machineID, context: context, publishedAt: Date(timeIntervalSince1970: 0)
            )
            XCTAssertEqual(state.name, expectedName)
        }
    }

    func testPublishedNameMatchesSettingsFallback() throws {
        let context = try makeContext()
        for (hostName, _) in hostNameExpectations {
            let state = try service(hostName: hostName).compose(
                machineID: machineID, context: context, publishedAt: Date(timeIntervalSince1970: 0)
            )
            XCTAssertEqual(state.name, MachineDisplayName.publishedFallback(hostName: hostName))
        }
    }

    func testStoredMachineDisplayNameWinsAfterTrimming() throws {
        defaults.set(" \tNamed Mac\n ", forKey: MachineDisplayName.defaultsKey)
        let context = try makeContext()
        for (hostName, _) in hostNameExpectations {
            let state = try service(hostName: hostName).compose(
                machineID: machineID, context: context, publishedAt: Date(timeIntervalSince1970: 0)
            )
            XCTAssertEqual(state.name, "Named Mac")
        }
    }

    func testBlankStoredNameTrimsHostOrUsesMac() throws {
        let context = try makeContext()
        for storedName in ["", " \t\n"] {
            defaults.set(storedName, forKey: MachineDisplayName.defaultsKey)
            for (hostName, expectedName) in hostNameExpectations {
                let state = try service(hostName: hostName).compose(
                    machineID: machineID, context: context, publishedAt: Date(timeIntervalSince1970: 0)
                )
                XCTAssertEqual(state.name, expectedName)
            }
        }
    }

    func testNonScalarKeyIsSkippedAndWarned() throws {
        var warnings: [String] = []
        let reader = service(warn: { warnings.append($0) })
        let valid = stateYAML(machineID: machineID)
        try writeRaw(id: machineID, content: valid)
        XCTAssertEqual(reader.readAll(fromRoot: tempDir).count, 1)
        let benign = CheckedYAMLLoaderTests.validDocument(
            valid, shadowing: "name", containing: "benign: true"
        )
        try writeRaw(id: machineID, content: benign)
        XCTAssertEqual(reader.readAll(fromRoot: tempDir).count, 1)
        XCTAssertTrue(warnings.isEmpty)

        for fixture in CheckedYAMLLoaderTests.nonScalarKeyFixtures {
            let yaml = CheckedYAMLLoaderTests.validDocument(
                valid, shadowing: "name", containing: fixture.yaml
            )
            XCTAssertThrowsError(try CheckedYAMLLoader.load(yaml: yaml), fixture.name) { error in
                XCTAssertEqual(error as? CheckedYAMLLoader.LoaderError, .nonScalarKey)
            }
            try writeRaw(id: machineID, content: yaml)
            XCTAssertTrue(reader.readAll(fromRoot: tempDir).isEmpty, fixture.name)
        }
        XCTAssertEqual(warnings.count, CheckedYAMLLoaderTests.nonScalarKeyFixtures.count)
        XCTAssertTrue(warnings.allSatisfy {
            $0.contains("skipped unreadable or unsupported machine state")
        })
    }

    func testResourceLimitDocumentsAreSkipped() throws {
        var warnings: [String] = []
        let reader = service(warn: { warnings.append($0) })
        let valid = stateYAML(machineID: machineID)
        try writeRaw(id: machineID, content: valid)
        XCTAssertEqual(reader.readAll(fromRoot: tempDir).count, 1)
        let benign = CheckedYAMLLoaderTests.validDocument(
            valid, shadowing: "name", containing: "benign: true"
        )
        try writeRaw(id: machineID, content: benign)
        XCTAssertEqual(reader.readAll(fromRoot: tempDir).count, 1)
        XCTAssertTrue(warnings.isEmpty)

        for fixture in CheckedYAMLLoaderTests.resourceLimitFixtures {
            let yaml = CheckedYAMLLoaderTests.validDocument(
                valid, shadowing: "name", containing: fixture.yaml
            )
            XCTAssertThrowsError(try CheckedYAMLLoader.load(yaml: yaml), fixture.name) { error in
                XCTAssertEqual(error as? CheckedYAMLLoader.LoaderError, fixture.error)
            }
            try writeRaw(id: machineID, content: yaml)
            let start = Date()
            XCTAssertTrue(reader.readAll(fromRoot: tempDir).isEmpty, fixture.name)
            XCTAssertLessThan(Date().timeIntervalSince(start), 1, fixture.name)
        }
        XCTAssertEqual(warnings.count, CheckedYAMLLoaderTests.resourceLimitFixtures.count)
        XCTAssertTrue(warnings.allSatisfy {
            $0.contains("skipped unreadable or unsupported machine state")
        })
    }
}

private struct FixedMachineDetection: AgentDetectionServiceProtocol {
    let installed: [PlatformTarget]
    func isInstalled(_ platform: PlatformTarget) -> Bool { installed.contains(platform) }
    func installedPlatforms() -> [PlatformTarget] { installed }
}
