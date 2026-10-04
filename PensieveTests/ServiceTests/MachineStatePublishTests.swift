import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class MachineStatePublishTests: XCTestCase {
    private var tempDir = ""
    private let fileService = FileService()
    private let machineA = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let machineB = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MachineStatePublishTests-\(UUID().uuidString)").path
        try fileService.createDirectory(at: tempDir)
    }

    override func tearDownWithError() throws {
        if !tempDir.isEmpty { try? fileService.deleteDirectory(at: tempDir) }
    }

    func testStateFileArrivesByteIdentical() async throws {
        let harness = try makeHarness()
        let clockA = PublishClock(Date(timeIntervalSince1970: 1_700_000_000))
        let coordinatorA = try await coordinator(root: harness.cloneA, id: machineA,
                                                 git: harness.git, clock: clockA)
        guard case .synced = await coordinatorA.runCycle() else { return XCTFail("A did not sync") }

        let clockB = PublishClock(Date(timeIntervalSince1970: 1_700_000_100))
        let coordinatorB = try await coordinator(root: harness.cloneB, id: machineB,
                                                 git: harness.git, clock: clockB)
        guard case .synced = await coordinatorB.runCycle() else { return XCTFail("B did not sync") }

        let path = "/machines/" + machineA + ".yaml"
        XCTAssertEqual(try fileService.readData(at: harness.cloneB + path),
                       try fileService.readData(at: harness.cloneA + path))
    }

    func testOwnSyncTouchesOnlyOwnStateFile() async throws {
        let harness = try makeHarness()
        let clockA = PublishClock(Date(timeIntervalSince1970: 1_700_000_000))
        let coordinatorA = try await coordinator(root: harness.cloneA, id: machineA,
                                                 git: harness.git, clock: clockA)
        _ = await coordinatorA.runCycle()

        let clockB = PublishClock(Date(timeIntervalSince1970: 1_700_000_100))
        let coordinatorB = try await coordinator(root: harness.cloneB, id: machineB,
                                                 git: harness.git, clock: clockB)
        _ = await coordinatorB.runCycle()
        let foreignPath = harness.cloneB + "/machines/" + machineA + ".yaml"
        let foreignBefore = try fileService.readData(at: foreignPath)

        clockB.value = Date(timeIntervalSince1970: 1_700_000_200)
        guard case .synced = await coordinatorB.runCycle() else { return XCTFail("second B cycle failed") }
        XCTAssertEqual(try fileService.readData(at: foreignPath), foreignBefore)
        XCTAssertEqual(try fileService.listDirectory(at: harness.cloneB + "/machines").sorted(),
                       [machineA + ".yaml", machineB + ".yaml"])
    }

    func testIdleCycleLeavesStateFileByteIdenticalAndCommitsNothing() async throws {
        let harness = try makeHarness()
        let clock = PublishClock(Date(timeIntervalSince1970: 1_700_000_000))
        let coordinator = try await coordinator(root: harness.cloneA, id: machineA,
                                                git: harness.git, clock: clock)
        guard case .synced = await coordinator.runCycle() else { return XCTFail("first cycle failed") }
        let statePath = harness.cloneA + "/machines/" + machineA + ".yaml"
        let stateBefore = try fileService.readData(at: statePath)
        let remoteHeadBefore = try rawGitOutput(["-C", harness.remotePath, "rev-parse", "HEAD"])

        clock.value = Date(timeIntervalSince1970: 1_700_000_100)
        guard case let .synced(pushed, _, _, headAdvanced) = await coordinator.runCycle() else {
            return XCTFail("second cycle failed")
        }

        XCTAssertFalse(pushed)
        XCTAssertFalse(headAdvanced)
        XCTAssertEqual(try fileService.readData(at: statePath), stateBefore)
        XCTAssertEqual(try rawGitOutput(["-C", harness.remotePath, "rev-parse", "HEAD"]),
                       remoteHeadBefore)
    }

    func testContentChangeRewritesStateAndPushes() async throws {
        let harness = try makeHarness()
        let clock = PublishClock(Date(timeIntervalSince1970: 1_700_000_000))
        let suiteName = isolatedDefaultsSuite("content-change")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = try await coordinator(root: harness.cloneA, id: machineA,
                                                git: harness.git, clock: clock, defaults: defaults)
        guard case .synced = await coordinator.runCycle() else { return XCTFail("first cycle failed") }
        let statePath = harness.cloneA + "/machines/" + machineA + ".yaml"
        let stateBefore = try fileService.readData(at: statePath)
        let remoteHeadBefore = try rawGitOutput(["-C", harness.remotePath, "rev-parse", "HEAD"])

        clock.value = Date(timeIntervalSince1970: 1_700_000_100)
        defaults.set("Renamed Mac", forKey: "machineDisplayName")
        guard case let .synced(pushed, _, _, headAdvanced) = await coordinator.runCycle() else {
            return XCTFail("second cycle failed")
        }

        XCTAssertTrue(pushed)
        XCTAssertTrue(headAdvanced)
        XCTAssertNotEqual(try fileService.readData(at: statePath), stateBefore)
        let parsed = try XCTUnwrap(machineStateService(defaults: defaults)
            .readAll(fromRoot: harness.cloneA).first { $0.machineID == machineA })
        XCTAssertEqual(parsed.name, "Renamed Mac")
        XCTAssertEqual(parsed.publishedAt, clock.value)
        XCTAssertNotEqual(try rawGitOutput(["-C", harness.remotePath, "rev-parse", "HEAD"]),
                          remoteHeadBefore)
    }

    func testMissingOwnStateFileRewritten() async throws {
        let harness = try makeHarness()
        let clock = PublishClock(Date(timeIntervalSince1970: 1_700_000_000))
        let suiteName = isolatedDefaultsSuite("missing")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = try await coordinator(root: harness.cloneA, id: machineA,
                                                git: harness.git, clock: clock, defaults: defaults)
        guard case .synced = await coordinator.runCycle() else { return XCTFail("first cycle failed") }
        let statePath = harness.cloneA + "/machines/" + machineA + ".yaml"
        try fileService.deleteFile(at: statePath)

        clock.value = Date(timeIntervalSince1970: 1_700_000_100)
        guard case let .synced(pushed, _, _, _) = await coordinator.runCycle() else {
            return XCTFail("second cycle failed")
        }

        XCTAssertTrue(pushed)
        let service = machineStateService(defaults: defaults)
        let expected = try service.compose(machineID: machineA, context: try makeContext(),
                                           publishedAt: clock.value)
        let parsed = try XCTUnwrap(service.readAll(fromRoot: harness.cloneA).first {
            $0.machineID == machineA
        })
        XCTAssertEqual(parsed, expected)
    }

    func testCorruptOwnStateFileRewritten() async throws {
        let harness = try makeHarness()
        let clock = PublishClock(Date(timeIntervalSince1970: 1_700_000_000))
        let suiteName = isolatedDefaultsSuite("corrupt")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = try await coordinator(root: harness.cloneA, id: machineA,
                                                git: harness.git, clock: clock, defaults: defaults)
        guard case .synced = await coordinator.runCycle() else { return XCTFail("first cycle failed") }
        let statePath = harness.cloneA + "/machines/" + machineA + ".yaml"
        try fileService.writeFile(at: statePath, content: "not: [valid")

        clock.value = Date(timeIntervalSince1970: 1_700_000_100)
        guard case let .synced(pushed, _, _, _) = await coordinator.runCycle() else {
            return XCTFail("second cycle failed")
        }

        XCTAssertTrue(pushed)
        let service = machineStateService(defaults: defaults)
        let expected = try service.compose(machineID: machineA, context: try makeContext(),
                                           publishedAt: clock.value)
        let parsed = try XCTUnwrap(service.readAll(fromRoot: harness.cloneA).first {
            $0.machineID == machineA
        })
        XCTAssertTrue(parsed.contentEquals(expected))
    }

    func testStatePublishFailureDoesNotBlockSync() async throws {
        let harness = try makeHarness()
        let clock = PublishClock(Date(timeIntervalSince1970: 1_700_000_000))
        let coordinator = try await coordinator(
            root: harness.cloneA, id: machineA, git: harness.git, clock: clock,
            stateService: ThrowingMachineStateService()
        )

        guard case let .synced(_, warnings, _, _) = await coordinator.runCycle() else {
            return XCTFail("publication failure blocked sync")
        }
        XCTAssertTrue(warnings.contains { $0.contains("Machine state not published") })
    }

    private func coordinator(
        root: String, id: String, git: GitService, clock: PublishClock,
        stateService injectedStateService: MachineStateServicing? = nil,
        defaults: UserDefaults? = nil
    ) async throws -> SyncCoordinator {
        let container = try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let engine = SyncEngine(
            gitService: AllowlistedRemoteGit(wrapping: git), manifestService: ManifestService(),
            storeRebuildService: StoreRebuildService(), fileService: fileService,
            lockPath: tempDir + "/" + id + ".lock"
        )
        let stateDefaults: UserDefaults
        if let defaults {
            stateDefaults = defaults
        } else {
            let suiteName = isolatedDefaultsSuite(id)
            stateDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            stateDefaults.removePersistentDomain(forName: suiteName)
        }
        let stateService = injectedStateService ?? machineStateService(defaults: stateDefaults)
        let coordinator = await Task.detached { SyncCoordinator(modelContainer: container) }.value
        await coordinator.configure(
            engine: engine, git: git, credentials: PublishEmptyCredentials(),
            rebuildService: StoreRebuildService(), root: root, audit: PublishNullAudit(),
            machineIdentity: FixedMachineIdentity(value: id), machineStateService: stateService,
            now: { clock.value }
        )
        return coordinator
    }

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        ))
    }

    private func machineStateService(defaults: UserDefaults) -> MachineStateService {
        MachineStateService(
            fileService: fileService, agentDetection: EmptyMachineDetection(),
            defaults: defaults,
            deployState: { DeployState(schemaVersion: 1, records: []) },
            hostName: { "Fixture Mac" }, appVersion: { "0.12.0" }, warn: { _ in }
        )
    }

    private func makeHarness() throws -> PublishHarness {
        let remotePath = tempDir + "/remote.git"
        XCTAssertEqual(try rawGit(["init", "--bare", remotePath]), 0)
        let remote = "file://" + remotePath
        let seed = tempDir + "/seed"
        try fileService.createDirectory(at: seed)
        let git = GitService()
        try git.initRepository(at: seed)
        try git.setRemote(remote, at: seed)
        try ManifestService().write(
            ManifestSnapshot(schemaVersion: ManifestService.currentSchemaVersion,
                             categories: [], projects: [], skills: []),
            toRoot: seed
        )
        try fileService.writeFile(at: seed + "/.gitattributes",
                                  content: "manifest/categories/*.yaml merge=union\n"
                                    + "manifest/scenarios/*.yaml merge=union\n"
                                    + "manifest/projects.yaml merge=union\n")
        try fileService.writeFile(at: seed + "/.gitignore", content: ".DS_Store\n")
        XCTAssertTrue(try git.stageAllAndCommit(at: seed, message: "seed"))
        try git.push(at: seed, credential: nil)
        let cloneA = tempDir + "/cloneA"
        let cloneB = tempDir + "/cloneB"
        try git.clone(remote: remote, into: cloneA, credential: nil)
        try git.clone(remote: remote, into: cloneB, credential: nil)
        return PublishHarness(git: git, remotePath: remotePath, cloneA: cloneA, cloneB: cloneB)
    }

    private func rawGit(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func rawGitOutput(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return try XCTUnwrap(String(data: data, encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct PublishHarness {
    let git: GitService
    let remotePath: String
    let cloneA: String
    let cloneB: String
}
private final class PublishClock { var value: Date; init(_ value: Date) { self.value = value } }
private struct PublishNullAudit: SyncAuditWriting { func record(category: String, detail: String) {} }
private struct PublishEmptyCredentials: CredentialStoreProtocol {
    func credential(forHost host: String) -> GitCredential? { nil }
    func store(token: String, username: String, forHost host: String) throws {}
    func delete(forHost host: String) throws {}
}
private struct ThrowingMachineStateService: MachineStateServicing {
    func compose(machineID: String, context: ModelContext, publishedAt: Date) throws -> MachineState {
        throw PublishFixtureError.compose
    }
    func write(_ state: MachineState, toRoot root: String) throws {}
    func readAll(fromRoot root: String) -> [MachineState] { [] }
}
private enum PublishFixtureError: LocalizedError {
    case compose
    var errorDescription: String? { "fixture compose failure" }
}
