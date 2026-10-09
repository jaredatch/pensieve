import SwiftData
import XCTest
@testable import Pensieve

@MainActor
extension DeployIntentModelTests {
    func testCriterionDLaunchAndSyncNeverAdoptIntentlessDeploys() throws {
        let lockPath = TestTemporaryDirectory.path + "PensieveIntentless-" + UUID().uuidString + ".lock"
        defer { try? FileManager.default.removeItem(atPath: lockPath) }
        let harness = try makeHarness(lockPath: lockPath)
        let skill = try insertSkill(context: harness.context)
        try writeIntegrationSkill(skill, root: harness.root)
        harness.platformVM.deploy(skill: skill, platform: .codex, context: harness.context)
        try writeIntegrationManifest(harness)

        _ = LaunchReconciler(
            migrationService: StoreMigrationService(skillStore: SkillStore(fileService: FileService(),
                baseDir: TestPaths.skillsDir, storeRoot: TestPaths.storeRoot)),
            root: harness.root,
            lockPath: lockPath,
            git: TestPaths.git
        ).reconcileOnLaunch(context: harness.context, alreadyMigrated: true)
        _ = IntentReconciler(
            platformVM: harness.platformVM,
            machineIdentity: DeployIntentIdentityForSyncTest(id: localID)
        ).reconcile(context: harness.context)
        try assertNoIntegrationIntent(harness, skill: skill)

        let engine = SyncEngine(
            gitService: SyncEngineTests.StubGit(),
            manifestService: ManifestService(),
            storeRebuildService: StoreRebuildService(),
            fileService: FileService(),
            lockPath: lockPath
        )
        _ = try engine.sync(
            root: harness.root, message: "intentless", credential: nil, context: harness.context
        )
        _ = IntentReconciler(
            platformVM: harness.platformVM,
            machineIdentity: DeployIntentIdentityForSyncTest(id: localID)
        ).reconcile(context: harness.context)

        try assertNoIntegrationIntent(harness, skill: skill)
        XCTAssertTrue(harness.platformVM.isDeployed(skill: skill, platform: .codex))
    }

    func testCriterionOSyncLockRefusesMidCycleFlipThenLaterCyclesPreserveIt() throws {
        let lockPath = TestTemporaryDirectory.path + "PensieveIntentCycle-" + UUID().uuidString + ".lock"
        defer { try? FileManager.default.removeItem(atPath: lockPath) }
        let harness = try makeHarness(lockPath: lockPath)
        let skill = try insertSkill(context: harness.context)
        try writeIntegrationSkill(skill, root: harness.root)
        try writeIntegrationManifest(harness)
        let engine = SyncEngine(
            gitService: SyncEngineTests.StubGit(),
            manifestService: ManifestService(),
            storeRebuildService: StoreRebuildService(),
            fileService: FileService(),
            lockPath: lockPath
        )
        var refused = false

        _ = try engine.sync(
            root: harness.root,
            message: "cycle holding lock",
            credential: nil,
            context: harness.context,
            prepare: { context in
                do {
                    _ = try harness.model.set(
                        true, skill: skill, platform: .codex, target: .userWide, context: context
                    )
                    XCTFail("the flip must be refused while SyncEngine owns its lock")
                } catch {
                    refused = true
                }
            }
        )

        XCTAssertTrue(refused)
        XCTAssertEqual(harness.model.error, "Sync is running. Try again when it finishes.")
        try assertNoIntegrationIntent(harness, skill: skill)
        XCTAssertFalse(try harness.platformVM.removalOperation(
            skill: skill, platform: .codex, target: .userWide).classify().isOwned)

        _ = try harness.model.set(
            true, skill: skill, platform: .codex, target: .userWide, context: harness.context
        )
        XCTAssertNil(harness.model.error)
        _ = try engine.sync(
            root: harness.root, message: "cycle preserving flip", credential: nil, context: harness.context
        )

        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 1)
        XCTAssertTrue(harness.manifestFileService.fileExists(at: integrationIntentPath(harness, skill: skill)))
        XCTAssertTrue(harness.platformVM.isDeployed(skill: skill, platform: .codex))
        XCTAssertFalse(harness.manifestFileService.fileExists(at: harness.root + "/sync.lock"))
        XCTAssertFalse(harness.manifestFileService.fileExists(at: harness.root + "/.pensieve-sync.lock"))
    }
}

private struct DeployIntentIdentityForSyncTest: MachineIdentityProviding {
    let id: String
    func identifier() throws -> String { id }
}

@MainActor
private extension DeployIntentModelTests {
    func writeIntegrationSkill(_ skill: Skill, root: String) throws {
        let directory = root + "/skills/" + skill.directoryName
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try "---\nname: Alpha\ndescription: Alpha description\n---\n\nBody\n"
            .write(toFile: directory + "/SKILL.md", atomically: true, encoding: .utf8)
    }

    func writeIntegrationManifest(_ harness: Harness) throws {
        let service = ManifestService(fileService: harness.manifestFileService)
        try service.write(try service.snapshot(from: harness.context), toRoot: harness.root)
    }

    func integrationIntentPath(_ harness: Harness, skill: Skill) -> String {
        harness.root + "/manifest/deploys/" + localID + "/" + skill.directoryName + ".yaml"
    }

    func assertNoIntegrationIntent(_ harness: Harness, skill: Skill) throws {
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
        XCTAssertFalse(harness.manifestFileService.fileExists(at: integrationIntentPath(harness, skill: skill)))
    }
}
