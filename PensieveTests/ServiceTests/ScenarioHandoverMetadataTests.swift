import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ScenarioHandoverMetadataTests: XCTestCase {
    func testAbsentAndPartialManifestPreserveCachedMetadataThroughNextRebuild() throws {
        for partial in [false, true] {
            let harness = try HandoverHarness(defaults: isolatedDefaults("partial-\(partial)"))
            defer { try? harness.cleanUp() }
            let skill = try harness.seed()
            skill.createdAt = Date(timeIntervalSince1970: 10)
            skill.tags = ["cached"]
            let category = Pensieve.Category(name: "Cached")
            category.skillSlugs = [skill.directoryName]
            category.projectKeys = ["marker:project"]
            harness.context.insert(category)
            try harness.context.save()
            let cached = try harness.manifest.live.snapshot(from: harness.context)
            try harness.files.deleteDirectory(at: harness.root + "/manifest")
            if partial {
                try harness.files.writeFile(at: harness.root + "/manifest/manifest.yaml", content: "schema_version: 5\n")
            }
            XCTAssertFalse(harness.launch().ingestionNeedsRetry)
            let written = try harness.manifest.read(fromRoot: harness.root)
            XCTAssertEqual(written.categories, cached.categories)
            XCTAssertEqual(written.skills, cached.skills)
            XCTAssertTrue(cached.deployIntents.allSatisfy(written.deployIntents.contains))
            let context = harness.freshContext()
            XCTAssertFalse(StoreRebuildService(fileService: harness.files, manifestService: harness.manifest)
                .rebuild(fromRoot: harness.root, context: context).storeUnreadable)
            XCTAssertEqual(try context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name), ["Cached"])
            XCTAssertEqual(try context.fetch(FetchDescriptor<Skill>()).first?.tags, ["cached"])
            try harness.assertComplete()
        }
    }

    func testHandoverPreservesMetadataUniqueToEitherCacheOrDisk() throws {
        let harness = try HandoverHarness(defaults: isolatedDefaults())
        defer { try? harness.cleanUp() }
        let skill = try harness.seed()
        skill.createdAt = Date(timeIntervalSince1970: 10)
        let category = Pensieve.Category(name: "Cached")
        category.skillSlugs = ["skill"]
        harness.context.insert(category)
        try harness.context.save()
        let cached = try harness.manifest.live.snapshot(from: harness.context)
        var disk = cached
        disk.categories = [CategoryRecord(name: "Disk", projectKeys: [], skillSlugs: ["disk"])]
        disk.skills = [SkillOverlay(slug: "disk", createdAt: Date(timeIntervalSince1970: 10), scope: .user,
                                   tags: ["disk"], cursor: nil, agents: [], origin: .authored)]
        disk.deployIntents = [DeployIntentRecord(machineID: harness.identity.id, skillSlug: "disk",
                                                platformRaw: "codex", projectKey: nil)]
        try harness.manifest.live.write(disk, toRoot: harness.root)
        try harness.handover().handOver(context: harness.freshContext())
        let written = try harness.manifest.read(fromRoot: harness.root)
        XCTAssertTrue((cached.categories + disk.categories).allSatisfy(written.categories.contains))
        XCTAssertTrue((cached.skills + disk.skills).allSatisfy(written.skills.contains))
        XCTAssertTrue((cached.deployIntents + disk.deployIntents).allSatisfy(written.deployIntents.contains))
    }

    func testFailedRebuildSaveKeepsUnsavedSkillsScenarioOwnershipUntilNextLaunch() throws {
        let harness = try HandoverHarness(defaults: isolatedDefaults())
        defer { try? harness.cleanUp() }
        let skill = try harness.seed()
        let before = try harness.deployedFiles()
        // A rebuild reconstitutes this live skill in the launch context, but its save fails.
        let skillID = skill.id
        harness.context.delete(skill)
        try harness.context.save()
        let launchContext = harness.freshContext()
        launchContext.autosaveEnabled = false
        let restored = Skill(name: "skill", skillDescription: "Description", directoryName: "skill")
        restored.id = skillID
        let rebuild = UnsavedSkillRebuild(skill: restored)
        let outcome = LaunchReconciler(
            rebuildService: rebuild, fileService: harness.files, manifestService: harness.manifest,
            root: harness.root, lockPath: harness.root + "/sync.lock", scenarioHandover: harness.handover()
        ).reconcileOnLaunch(context: launchContext, alreadyMigrated: true)
        XCTAssertFalse(outcome.ingestionNeedsRetry)
        XCTAssertTrue(launchContext.hasChanges)
        XCTAssertFalse(outcome.rebuild.warnings.isEmpty)
        XCTAssertEqual(try harness.freshContext().fetchCount(FetchDescriptor<ScenarioAssignment>()), 2)
        XCTAssertFalse(harness.defaults.bool(forKey: ScenarioHandover.doneKey))
        XCTAssertEqual(harness.manifest.writes, 0)
        XCTAssertEqual(try harness.deployedFiles(), before)
        let deploys = HandoverDeployments(root: harness.root)
        XCTAssertFalse(IntentReconciler(platformVM: deploys.platformVM, machineIdentity: harness.identity)
            .reconcile(context: launchContext).hasFailures)
        XCTAssertEqual(deploys.removeCalls, 0)
        try launchContext.save()
        XCTAssertFalse(harness.launch().ingestionNeedsRetry)
        try harness.assertComplete()
        XCTAssertEqual(try harness.deployedFiles(), before)
    }

    func testUnmanagedPairsDoNotAttemptAnUnneededManifestWrite() throws {
        let harness = try HandoverHarness(defaults: isolatedDefaults())
        defer { try? harness.cleanUp() }
        try harness.seed("has space", platforms: [.codex])
        let before = try harness.deployedFiles()
        let manifest = try harness.manifest.read(fromRoot: harness.root)
        harness.manifest.failAllWrites = true
        XCTAssertFalse(harness.launch().ingestionNeedsRetry)
        try harness.assertComplete([])
        XCTAssertEqual(harness.manifest.writes, 0)
        XCTAssertEqual(try harness.manifest.read(fromRoot: harness.root), manifest)
        XCTAssertEqual(try harness.deployedFiles(), before)
        XCTAssertTrue(harness.logs.contains("Left unmanaged: skill 'has space', agent 'codex'."))
    }
}

private struct UnsavedSkillRebuild: StoreRebuildServiceProtocol {
    let skill: Skill
    func rebuild(fromRoot root: String, context: ModelContext) -> RebuildResult {
        context.insert(skill)
        // Inject the same boundary failure the real rebuild reports without rolling back its context.
        do { try failedSave(context) } catch {
            return RebuildResult(skillsInserted: 1, warnings: ["Rebuild saving local store failed: \(error)"])
        }
        return RebuildResult()
    }
    private func failedSave(_ context: ModelContext) throws { throw ScenarioStubFailure() }
}
