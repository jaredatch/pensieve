import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class MachineStateDisplayPathTests: XCTestCase {
    private let fileService = FileService()
    private let home = "/Users/fixture"
    private let machineID = "5A9C2E31-8F04-4D2B-9C61-0B7A43F1D002"
    private var tempDir = ""

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.url
            .appendingPathComponent("MachineStateDisplayPathTests-\(UUID().uuidString)").path
        try fileService.createDirectory(at: tempDir)
    }

    override func tearDownWithError() throws {
        if !tempDir.isEmpty { try? fileService.deleteDirectory(at: tempDir) }
    }

    func testComposePublishesOnlyHomeAbbreviatedPaths() throws {
        let context = try makeContext(projects: [
            project("home", path: home),
            project("nested", path: home + "/Projects/demo"),
            project("outside", path: "/Volumes/Work/demo"),
            Project(name: "Keyless", path: home + "/Projects/keyless")
        ])

        let state = try service().compose(machineID: machineID, context: context, publishedAt: Date())

        XCTAssertEqual(state.projects, [
            MachineStateProject(identityKey: "home", kind: "git-remote", name: "home", path: "~"),
            MachineStateProject(identityKey: "nested", kind: "git-remote", name: "nested",
                                path: "~/Projects/demo"),
            MachineStateProject(identityKey: "outside", kind: "git-remote", name: "outside")
        ])
    }

    func testComposeNormalizesPathsBeforeHomeAdmission() {
        let records = MachineStateService.projectRecords([
            project("dot", path: home + "/Projects/./Demo"),
            project("escape", path: home + "/../../Volumes/Client/x"),
            project("inside", path: home + "/Projects/../Shared"),
            project("trailing", path: home + "/Projects/Demo/")
        ], homeDirectory: home)

        XCTAssertEqual(records, [
            MachineStateProject(identityKey: "dot", kind: "git-remote", name: "dot",
                                path: "~/Projects/Demo"),
            MachineStateProject(identityKey: "escape", kind: "git-remote", name: "escape"),
            MachineStateProject(identityKey: "inside", kind: "git-remote", name: "inside", path: "~/Shared"),
            MachineStateProject(identityKey: "trailing", kind: "git-remote", name: "trailing",
                                path: "~/Projects/Demo")
        ])
    }

    func testRoundTripAndLegacyBytesRemainStable() throws {
        let dated = Date(timeIntervalSince1970: 1_700_000_000)
        let state = makeState(projects: [
            MachineStateProject(identityKey: "key", kind: "git-remote", name: "Project", path: "~/Work")
        ], publishedAt: dated)
        try assertFixedPoint(state, label: "path")

        let legacy = makeState(projects: [
            MachineStateProject(
                identityKey: "github.com/example/demo",
                kind: "git-remote",
                name: "Project\tLine\nControl\u{1}"
            )
        ], publishedAt: dated)
        try service().write(legacy, toRoot: tempDir + "/legacy")
        let bytes = try fileService.readFile(at: statePath(root: tempDir + "/legacy"))
        XCTAssertEqual(bytes, legacyBytes)
        XCTAssertEqual(service().readAll(fromRoot: tempDir + "/legacy"), [legacy])
    }

    func testOlderAndInvalidPathValuesReadAsAbsent() throws {
        let invalidValues = [
            "42", "true", "null", "[one]", "{nested: value}",
            "\"/Users/other/secret\"", "\"relative/path\"", "\"\"",
            "\"~/../secret\"", "\"~/Projects/../secret\"", "\"~other/secret\""
        ]
        try assertParsedPath(valueLine: nil, expected: nil)
        for value in invalidValues {
            try assertParsedPath(valueLine: value, expected: nil)
        }
        for scalar in PathJoiningScalars.values {
            let path = "~/" + scalar + "project"
            try assertParsedPath(valueLine: "\"" + path + "\"", expected: path)
            try assertParsedPath(valueLine: "\"" + path + "/../secret\"", expected: nil)
        }
        try assertParsedPath(valueLine: "\"~\"", expected: "~")
        try assertParsedPath(valueLine: "\"~/Projects/demo\"", expected: "~/Projects/demo")
    }

    func testPathParticipatesInContentEquality() {
        let original = makeState(projects: [
            MachineStateProject(identityKey: "key", kind: "git-remote", name: "Project", path: "~/One")
        ])
        let moved = makeState(projects: [
            MachineStateProject(identityKey: "key", kind: "git-remote", name: "Project", path: "~/Two")
        ], publishedAt: original.publishedAt.addingTimeInterval(60))
        let timestampOnly = makeState(projects: original.projects,
                                      publishedAt: original.publishedAt.addingTimeInterval(60))

        XCTAssertFalse(original.contentEquals(moved))
        XCTAssertTrue(original.contentEquals(timestampOnly))
    }

    func testProductionPublishStepRepublishesMovedPathOnceThenSkips() throws {
        let project = project("key", name: "Project", path: home + "/One")
        let context = try makeContext(projects: [project])
        let counting = CountingMachineStateService(base: service())
        let root = tempDir + "/moved"

        XCTAssertTrue(try counting.publishIfChanged(
            machineID: machineID, context: context,
            publishedAt: Date(timeIntervalSince1970: 1), root: root
        ))
        project.path = home + "/Two"
        try context.save()
        XCTAssertTrue(try counting.publishIfChanged(
            machineID: machineID, context: context,
            publishedAt: Date(timeIntervalSince1970: 2), root: root
        ))
        XCTAssertFalse(try counting.publishIfChanged(
            machineID: machineID, context: context,
            publishedAt: Date(timeIntervalSince1970: 3), root: root
        ))

        XCTAssertEqual(counting.writeCount, 2)
        XCTAssertEqual(counting.readAll(fromRoot: root).first?.projects.first?.path, "~/Two")
    }

    func testProductionPublishStepWritesTenStableCyclesOnce() throws {
        let context = try makeContext(projects: duplicateProjects(reversed: true))
        let counting = CountingMachineStateService(base: service())
        let root = tempDir + "/cycles"

        for tick in 0..<10 {
            _ = try counting.publishIfChanged(
                machineID: machineID, context: context,
                publishedAt: Date(timeIntervalSince1970: TimeInterval(tick)), root: root
            )
        }

        XCTAssertEqual(counting.writeCount, 1)
    }

    func testDuplicateIdentityPathIsDeterministicAcrossFetchOrderAndCycles() throws {
        let projects = duplicateProjects(reversed: false)
        let first = MachineStateService.projectRecords(projects, homeDirectory: home)
        let second = MachineStateService.projectRecords(projects.reversed(), homeDirectory: home)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.first?.path, "~/Alpha")
    }

    func testDuplicateIdentityUsesExactBytesForCanonicallyEquivalentPaths() {
        let composed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        let forward = MachineStateService.projectRecords([
            project("shared", name: "Same", path: home + "/" + composed),
            project("shared", name: "Same", path: home + "/" + decomposed)
        ], homeDirectory: home)
        let reverse = MachineStateService.projectRecords([
            project("shared", name: "Same", path: home + "/" + decomposed),
            project("shared", name: "Same", path: home + "/" + composed)
        ], homeDirectory: home)

        XCTAssertEqual(Array(try XCTUnwrap(forward.first?.path).utf8),
                       Array(("~/" + decomposed).utf8))
        XCTAssertEqual(Array(try XCTUnwrap(reverse.first?.path).utf8),
                       Array(("~/" + decomposed).utf8))
    }

    private func assertParsedPath(valueLine: String?, expected: String?) throws {
        let pathField = valueLine.map { ", path: \($0)" } ?? ""
        let yaml = rawState(projectLine: "  - {identity_key: key, kind: git-remote, name: Project\(pathField)}")
        let root = tempDir + "/parse-" + UUID().uuidString
        try fileService.createDirectory(at: root + "/machines")
        try fileService.writeFile(at: statePath(root: root), content: yaml)

        let state = try XCTUnwrap(service().readAll(fromRoot: root).first)
        XCTAssertEqual(state.projects, [
            MachineStateProject(identityKey: "key", kind: "git-remote", name: "Project", path: expected),
            MachineStateProject(identityKey: "valid", kind: "marker", name: "Valid", path: "~/Valid")
        ])
        XCTAssertEqual(state.name, "Fixture Mac")
        XCTAssertEqual(state.appVersion, "0.13.0")
        XCTAssertEqual(state.agents, [])
        XCTAssertEqual(state.userDeploys, [MachineStateUserDeploy(slug: "skill", platform: "codex")])
        XCTAssertEqual(state.projectDeploys, [])
    }

    private func assertFixedPoint(_ state: MachineState, label: String) throws {
        let first = tempDir + "/\(label)-first"
        let second = tempDir + "/\(label)-second"
        try service().write(state, toRoot: first)
        let parsed = try XCTUnwrap(service().readAll(fromRoot: first).first)
        XCTAssertEqual(parsed, state)
        try service().write(parsed, toRoot: second)
        XCTAssertEqual(try fileService.readData(at: statePath(root: first)),
                       try fileService.readData(at: statePath(root: second)))
    }

    private func duplicateProjects(reversed: Bool) -> [Project] {
        let alpha = project("shared", name: "Same", path: home + "/Alpha")
        let zulu = project("shared", name: "Same", path: home + "/Zulu")
        return reversed ? [zulu, alpha] : [alpha, zulu]
    }

    private func project(_ key: String, name: String? = nil, path: String) -> Project {
        let project = Project(name: name ?? key, path: path)
        project.identityKey = key
        project.identityKind = "git-remote"
        return project
    }

    private func makeContext(projects: [Project]) throws -> ModelContext {
        let context = ModelContext(try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        ))
        projects.forEach(context.insert)
        try context.save()
        return context
    }

    private func service() -> MachineStateService {
        MachineStateService(
            fileService: fileService,
            agentDetection: EmptyMachineDetection(),
            deployState: { DeployState(schemaVersion: 1, records: []) },
            homeDirectory: home,
            hostName: { "Fixture Mac" },
            appVersion: { "0.13.0" },
            warn: { _ in }
        )
    }

    private func makeState(
        projects: [MachineStateProject],
        publishedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> MachineState {
        MachineState(
            schemaVersion: 1,
            machineID: machineID,
            name: "Fixture Mac",
            appVersion: "0.13.0",
            publishedAt: publishedAt,
            agents: [],
            projects: projects,
            userDeploys: [MachineStateUserDeploy(slug: "skill", platform: "codex")],
            projectDeploys: []
        )
    }

    private func statePath(root: String) -> String { root + "/machines/" + machineID + ".yaml" }

}

extension MachineStateDisplayPathTests {
    private func rawState(projectLine: String) -> String {
        """
        schema_version: 1
        machine_id: \(machineID)
        name: Fixture Mac
        app_version: 0.13.0
        published_at: 2023-11-14T22:13:20Z
        agents: []
        projects:
        \(projectLine)
          - {identity_key: valid, kind: marker, name: Valid, path: "~/Valid"}
        user_deploys:
          - {slug: skill, platform: codex}
        project_deploys: []
        """
    }

    private var legacyBytes: String {
        #"""
        schema_version: 1
        machine_id: "\#(machineID)"
        name: "Fixture Mac"
        app_version: "0.13.0"
        published_at: 2023-11-14T22:13:20Z
        agents: []
        projects:
          - {identity_key: "github.com\/example\/demo", kind: "git-remote", name: "Project\tLine\nControl\u0001"}
        user_deploys:
          - {slug: "skill", platform: "codex"}
        project_deploys: []

        """#
    }
}

private final class CountingMachineStateService: MachineStateServicing {
    let base: MachineStateService
    var writeCount = 0

    init(base: MachineStateService) {
        self.base = base
    }

    func compose(machineID: String, context: ModelContext, publishedAt: Date) throws -> MachineState {
        try base.compose(machineID: machineID, context: context, publishedAt: publishedAt)
    }

    func write(_ state: MachineState, toRoot root: String) throws {
        writeCount += 1
        try base.write(state, toRoot: root)
    }

    func readAll(fromRoot root: String) -> [MachineState] {
        base.readAll(fromRoot: root)
    }
}
