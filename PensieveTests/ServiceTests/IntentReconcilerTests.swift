import SwiftData
import XCTest
@testable import Pensieve

private struct IntentIdentityStub: MachineIdentityProviding {
    let id: String
    func identifier() throws -> String { id }
}

@MainActor
final class IntentReconcilerTests: XCTestCase {
    private let localID = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let remoteID = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"

    func testDeploysAddressedIntent() throws {
        let harness = try makeHarness(installed: [.codex])
        let addressed = try insertSkill("addressed", context: harness.context)
        let remoteOnly = try insertSkill("remote-only", context: harness.context)
        insertIntent(machineID: localID, skill: addressed, platform: .codex, context: harness.context)
        insertIntent(machineID: remoteID, skill: remoteOnly, platform: .codex, context: harness.context)
        try harness.context.save()

        let result = harness.reconciler.reconcile(context: harness.context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(harness.linkService.linkCalls, [
            ScenarioRecordedLink(directoryName: "addressed", platform: .codex, projectPath: nil)
        ])
        XCTAssertEqual(try assignmentKeys(context: harness.context), [addressed.id.uuidString + "|codex"])
    }

    func testRetractsOnIntentRemoval() throws {
        let harness = try makeHarness(installed: [.codex])
        let skill = try insertSkill("alpha", context: harness.context)
        insertIntent(machineID: localID, skill: skill, platform: .codex, context: harness.context)
        try harness.context.save()
        _ = harness.reconciler.reconcile(context: harness.context)
        for row in try harness.context.fetch(FetchDescriptor<MachineDeployIntent>()) {
            harness.context.delete(row)
        }
        try harness.context.save()

        let result = harness.reconciler.reconcile(context: harness.context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(harness.linkService.unlinkCalls, [
            ScenarioRecordedLink(directoryName: "alpha", platform: .codex, projectPath: nil)
        ])
        XCTAssertTrue(try assignmentKeys(context: harness.context).isEmpty)
    }

    func testManualDeploySurvives() throws {
        let harness = try makeHarness(installed: [.codex])
        let skill = try insertSkill("manual", context: harness.context)
        harness.platformVM.deploy(skill: skill, platform: .codex, target: .userWide, context: harness.context)
        let path = harness.linkService.linkPath(skill: skill, platform: .codex, projectPath: nil)
        harness.linkService.unlinkCalls.removeAll()

        let result = harness.reconciler.reconcile(context: harness.context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertTrue(harness.linkService.unlinkCalls.isEmpty)
        XCTAssertTrue(harness.fileService.symlinks.contains(path))
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<DeployRecord>()), 1)
        XCTAssertTrue(try assignmentKeys(context: harness.context).isEmpty)
    }

    func testScenarioOwnedDeploySurvivesIntentRetraction() throws {
        let harness = try makeHarness(installed: [.codex])
        let skill = try insertSkill("shared", context: harness.context)
        insertIntent(machineID: localID, skill: skill, platform: .codex, context: harness.context)
        harness.context.insert(ScenarioAssignment(skillID: skill.id, platform: .codex))
        try harness.context.save()
        _ = harness.reconciler.reconcile(context: harness.context)
        let path = harness.linkService.linkPath(skill: skill, platform: .codex, projectPath: nil)
        harness.linkService.unlinkCalls.removeAll()
        for row in try harness.context.fetch(FetchDescriptor<MachineDeployIntent>()) {
            harness.context.delete(row)
        }
        try harness.context.save()

        let result = harness.reconciler.reconcile(context: harness.context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertTrue(harness.linkService.unlinkCalls.isEmpty)
        XCTAssertTrue(harness.fileService.symlinks.contains(path))
        XCTAssertTrue(try assignmentKeys(context: harness.context).isEmpty)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<ScenarioAssignment>()), 1)
    }

    func testDanglingSlugSkipped() throws {
        let harness = try makeHarness(installed: [.codex])
        harness.context.insert(MachineDeployIntent(
            machineID: localID, skillSlug: "missing", platformRaw: PlatformTarget.codex.rawValue
        ))
        try harness.context.save()

        let result = harness.reconciler.reconcile(context: harness.context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertTrue(result.outcomes.isEmpty)
        XCTAssertTrue(harness.linkService.linkCalls.isEmpty)
        XCTAssertTrue(try assignmentKeys(context: harness.context).isEmpty)
    }

    func testUninstalledPlatformSkipped() throws {
        let harness = try makeHarness(installed: [.codex])
        let skill = try insertSkill("alpha", context: harness.context)
        insertIntent(machineID: localID, skill: skill, platform: .hermes, context: harness.context)
        try harness.context.save()

        let result = harness.reconciler.reconcile(context: harness.context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertTrue(result.outcomes.isEmpty)
        XCTAssertTrue(harness.linkService.linkCalls.isEmpty)
        XCTAssertTrue(try assignmentKeys(context: harness.context).isEmpty)
    }

    func testProjectIntentNeverDeploysUserWide() throws {
        let harness = try makeHarness(installed: [.codex])
        let skill = try insertSkill("project-only", context: harness.context)
        harness.context.insert(MachineDeployIntent(
            machineID: localID,
            skillSlug: skill.directoryName,
            platformRaw: PlatformTarget.codex.rawValue,
            projectKey: "github.com/owner/project"
        ))
        try harness.context.save()

        let result = harness.reconciler.reconcile(context: harness.context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertTrue(result.outcomes.isEmpty)
        XCTAssertTrue(harness.linkService.linkCalls.isEmpty)
        XCTAssertTrue(try assignmentKeys(context: harness.context).isEmpty)
    }

    func testLaunchIngestedProjectIntentNeverDeploysUserWide() throws {
        let harness = try makeHarness(installed: [.codex])
        let root = NSTemporaryDirectory() + "PensieveLaunchProjectIntent-" + UUID().uuidString
        let fileService = FileService()
        defer { try? fileService.deleteDirectory(at: root) }
        let manifest = ManifestService(fileService: fileService)
        let slug = "launch-project-only"
        try fileService.writeFile(
            at: root + "/skills/" + slug + "/SKILL.md",
            content: SkillSerializer.serialize(name: slug, description: "project only", body: "body")
        )
        try manifest.write(
            ManifestSnapshot(
                schemaVersion: 5,
                categories: [],
                scenarios: [],
                projects: [],
                skills: [SkillOverlay(
                    slug: slug,
                    createdAt: Date(timeIntervalSince1970: 1),
                    scope: .user,
                    tags: [],
                    cursor: nil,
                    agents: [],
                    origin: .authored
                )],
                deployIntents: [DeployIntentRecord(
                    machineID: localID,
                    skillSlug: slug,
                    platformRaw: PlatformTarget.codex.rawValue,
                    projectKey: "github.com/owner/project"
                )]
            ),
            toRoot: root
        )

        let rebuild = StoreRebuildService(fileService: fileService, manifestService: manifest)
            .rebuild(fromRoot: root, context: harness.context)
        XCTAssertFalse(rebuild.storeUnreadable)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 1)

        let result = harness.reconciler.reconcile(context: harness.context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertTrue(result.outcomes.isEmpty)
        XCTAssertTrue(harness.linkService.linkCalls.isEmpty)
        XCTAssertTrue(try assignmentKeys(context: harness.context).isEmpty)
    }

    func testFailedRemovalRetries() throws {
        let harness = try makeHarness(installed: [.codex])
        let skill = try insertSkill("alpha", context: harness.context)
        insertIntent(machineID: localID, skill: skill, platform: .codex, context: harness.context)
        try harness.context.save()
        _ = harness.reconciler.reconcile(context: harness.context)
        for row in try harness.context.fetch(FetchDescriptor<MachineDeployIntent>()) {
            harness.context.delete(row)
        }
        try harness.context.save()
        harness.linkService.throwOnUnlink = [.codex]

        let failed = harness.reconciler.reconcile(context: harness.context)
        XCTAssertEqual(failed.failures.count, 1)
        XCTAssertEqual(try assignmentKeys(context: harness.context).count, 1)

        harness.linkService.throwOnUnlink = []
        let retry = harness.reconciler.reconcile(context: harness.context)
        XCTAssertFalse(retry.hasFailures)
        XCTAssertEqual(harness.linkService.unlinkCalls.count, 2)
        XCTAssertTrue(try assignmentKeys(context: harness.context).isEmpty)
    }

    func testAbsentArtifactClearsLedgerWithoutRemoval() throws {
        let harness = try makeHarness(installed: [.codex])
        let skill = try insertSkill("alpha", context: harness.context)
        harness.context.insert(IntentAssignment(skillID: skill.id, platformRaw: PlatformTarget.codex.rawValue))
        try harness.context.save()

        let result = harness.reconciler.reconcile(context: harness.context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertTrue(result.outcomes.isEmpty)
        XCTAssertTrue(harness.linkService.unlinkCalls.isEmpty)
        XCTAssertTrue(try assignmentKeys(context: harness.context).isEmpty)
    }
}

@MainActor
private extension IntentReconcilerTests {
    struct Harness {
        let context: ModelContext
        let reconciler: IntentReconciler
        let platformVM: PlatformViewModel
        let fileService: ScenarioRecordingFileService
        let linkService: ScenarioRecordingLinkService
    }

    func makeHarness(installed: [PlatformTarget]) throws -> Harness {
        let context = ModelContext(try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        ))
        let fileService = ScenarioRecordingFileService()
        let linkService = ScenarioRecordingLinkService(fileService: fileService)
        let platformVM = PlatformViewModel(
            fileService: fileService,
            linkService: linkService,
            cursorCompiler: ScenarioRecordingCursorCompiler(fileService: fileService),
            agentDetection: ScenarioStubDetection(installed: installed),
            deployStateStore: DeployStateStore(fileService: fileService)
        )
        return Harness(
            context: context,
            reconciler: IntentReconciler(
                platformVM: platformVM,
                machineIdentity: IntentIdentityStub(id: localID)
            ),
            platformVM: platformVM,
            fileService: fileService,
            linkService: linkService
        )
    }

    func insertSkill(_ slug: String, context: ModelContext) throws -> Skill {
        let skill = Skill(
            name: slug, skillDescription: slug + " description", tags: [], scope: .user,
            directoryName: slug, cursorConfig: nil, importedFrom: nil
        )
        context.insert(skill)
        try context.save()
        return skill
    }

    func insertIntent(
        machineID: String,
        skill: Skill,
        platform: PlatformTarget,
        context: ModelContext
    ) {
        context.insert(MachineDeployIntent(
            machineID: machineID,
            skillSlug: skill.directoryName,
            platformRaw: platform.rawValue
        ))
    }

    func assignmentKeys(context: ModelContext) throws -> [String] {
        try context.fetch(FetchDescriptor<IntentAssignment>()).map(\.key).sorted()
    }
}
