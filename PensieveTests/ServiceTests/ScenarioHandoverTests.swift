import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ScenarioHandoverTests: XCTestCase {
    func testLaunchTransfersActiveScenarioWithoutChangingFilesThenSurvivesRebuild() throws {
        let harness = try HandoverHarness(defaults: isolatedDefaults())
        defer { try? harness.cleanUp() }
        try harness.seed()
        let before = try harness.deployedFiles()
        XCTAssertTrue(before.values.allSatisfy { $0.identity != nil })
        let outcome = harness.launch()
        XCTAssertFalse(outcome.ingestionNeedsRetry)
        try harness.assertComplete()
        XCTAssertEqual(try harness.deployedFiles(), before)

        let context = harness.freshContext()
        let rebuilt = StoreRebuildService(fileService: harness.files, manifestService: harness.manifest)
            .rebuild(fromRoot: harness.root, context: context)
        XCTAssertFalse(rebuilt.storeUnreadable)
        try harness.assertComplete()
        let deploys = HandoverDeployments(root: harness.root)
        let reconciler = IntentReconciler(platformVM: deploys.platformVM, machineIdentity: harness.identity,
            handoverIsComplete: { false })
        XCTAssertFalse(reconciler.reconcile(context: context).hasFailures)
        XCTAssertEqual(deploys.createCalls, 0)
        XCTAssertEqual(deploys.removeCalls, 0)
        XCTAssertEqual(try harness.deployedFiles(), before)
    }

    func testSyncedHandoverDoesNotDeployOnAnotherMachine() throws {
        let harness = try HandoverHarness(defaults: isolatedDefaults())
        defer { try? harness.cleanUp() }
        try harness.seed()
        XCTAssertFalse(harness.launch().ingestionNeedsRetry)
        let other = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(other)
        let result = StoreRebuildService(fileService: harness.files, manifestService: harness.manifest)
            .rebuild(fromRoot: harness.root, context: context)
        XCTAssertFalse(result.storeUnreadable)
        let identity = HandoverIdentity()
        identity.id = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
        let deploys = HandoverDeployments(root: harness.root)
        XCTAssertFalse(IntentReconciler(platformVM: deploys.platformVM, machineIdentity: identity, handoverIsComplete: { false })
            .reconcile(context: context).hasFailures)
        XCTAssertEqual(deploys.createCalls, 0)
        XCTAssertEqual(deploys.removeCalls, 0)
        XCTAssertTrue(try context.fetch(FetchDescriptor<IntentAssignment>()).isEmpty)
        let handed = try harness.manifest.read(fromRoot: harness.root).deployIntents.filter {
            $0.projectKey == nil && $0.skillSlug == "skill"
        }
        XCTAssertEqual(handed.count, 2)
        XCTAssertTrue(handed.allSatisfy { $0.machineID == harness.identity.id })
    }

    func testManifestFailureRetainsUnhandedRowsAndRetriesAtLaunch() throws {
        for failedWrite in [1] {
            let harness = try HandoverHarness(defaults: isolatedDefaults("write-\(failedWrite)"))
            defer { try? harness.cleanUp() }
            try harness.seed()
            let before = try harness.deployedFiles()
            harness.manifest.failWrite = failedWrite
            XCTAssertFalse(harness.launch().ingestionNeedsRetry)
            let fresh = harness.freshContext()
            XCTAssertEqual(harness.nudges, 0)
            XCTAssertEqual(try fresh.fetch(FetchDescriptor<ScenarioAssignment>()).map { $0.platform.rawValue }.sorted(),
                           ["codex", "cursor"])
            XCTAssertFalse(harness.defaults.bool(forKey: ScenarioHandover.doneKey))
            XCTAssertNotNil(harness.defaults.object(forKey: ScenarioHandover.activeKey))
            XCTAssertEqual(try harness.deployedFiles(), before)
            try harness.assertUnrelatedIntentsUnchanged()
            XCTAssertEqual(try harness.manifest.read(fromRoot: harness.root).deployIntents.filter {
                harness.unrelated.contains($0)
            }.count, harness.unrelated.count)
            harness.manifest.failWrite = nil
            XCTAssertFalse(harness.launch().ingestionNeedsRetry)
            try harness.assertComplete()
            XCTAssertEqual(try harness.deployedFiles(), before)
        }
    }

    func testEachSaveBoundaryRecoversWithoutLosingOrDuplicatingPairs() throws {
        for failedSave in 1...2 {
            let harness = try HandoverHarness(defaults: isolatedDefaults("save-\(failedSave)"))
            defer { try? harness.cleanUp() }
            try harness.seed()
            let before = try harness.deployedFiles()
            var saves = 0
            let handover = harness.handover { context in
                saves += 1
                let durable = try harness.manifest.read(fromRoot: harness.root).deployIntents
                XCTAssertEqual(durable.filter { $0.skillSlug == "skill" && $0.projectKey == nil }.count,
                               2, "all manifest intents must precede ownership and retirement saves")
                if saves == failedSave { throw DeployStubFailure() }
                try context.save()
            }
            XCTAssertFalse(harness.launch(handover).ingestionNeedsRetry)
            XCTAssertFalse(harness.defaults.bool(forKey: ScenarioHandover.doneKey))
            XCTAssertNotNil(harness.defaults.object(forKey: ScenarioHandover.activeKey))
            let remaining = try harness.freshContext().fetch(FetchDescriptor<ScenarioAssignment>())
            XCTAssertEqual(remaining.map { $0.platform.rawValue }.sorted(), ["codex", "cursor"])
            XCTAssertEqual(try harness.deployedFiles(), before)
            try harness.assertUnrelatedIntentsUnchanged()
            XCTAssertFalse(harness.launch().ingestionNeedsRetry)
            try harness.assertComplete()
            XCTAssertEqual(try harness.deployedFiles(), before)
        }
    }

    func testMachineIdentityFailureAndInvalidIdentityRetainRowsUntilRetry() throws {
        for invalid in [false, true] {
            let harness = try HandoverHarness(defaults: isolatedDefaults("identity-\(invalid)"))
            defer { try? harness.cleanUp() }
            try harness.seed()
            let before = try harness.deployedFiles()
            let durable = try harness.manifest.read(fromRoot: harness.root)
            harness.identity.fails = !invalid
            if invalid { harness.identity.id = "not-canonical" }
            XCTAssertFalse(harness.launch().ingestionNeedsRetry)
            XCTAssertEqual(try harness.freshContext().fetchCount(FetchDescriptor<ScenarioAssignment>()), 2)
            XCTAssertEqual(harness.manifest.writes, 0)
            XCTAssertEqual(try harness.manifest.read(fromRoot: harness.root), durable)
            XCTAssertFalse(harness.defaults.bool(forKey: ScenarioHandover.doneKey))
            XCTAssertEqual(try harness.deployedFiles(), before)
            harness.identity.fails = false
            harness.identity.id = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
            XCTAssertFalse(harness.launch().ingestionNeedsRetry)
            try harness.assertComplete()
        }
    }

    func testRemainingScenarioOwnershipProtectsAnInterruptedPair() throws {
        let harness = try HandoverHarness(defaults: isolatedDefaults())
        defer { try? harness.cleanUp() }
        try harness.seed()
        let before = try harness.deployedFiles()
        var saves = 0
        let handover = harness.handover { context in
            saves += 1
            if saves == 2 { throw DeployStubFailure() }
            try context.save()
        }
        XCTAssertFalse(harness.launch(handover).ingestionNeedsRetry)
        let fresh = harness.freshContext()
        for row in try fresh.fetch(FetchDescriptor<MachineDeployIntent>()) where row.projectKey == nil {
            fresh.delete(row)
        }
        try fresh.save()
        let deploys = HandoverDeployments(root: harness.root)
        XCTAssertFalse(IntentReconciler(platformVM: deploys.platformVM, machineIdentity: harness.identity,
            handoverIsComplete: { false })
            .reconcile(context: fresh).hasFailures)
        XCTAssertEqual(deploys.removeCalls, 0)
        XCTAssertEqual(try harness.deployedFiles(), before)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<ScenarioAssignment>()), 2)
        XCTAssertFalse(harness.launch().ingestionNeedsRetry)
        try harness.assertComplete()
    }

    func testFetchFailuresKeepOwnershipAndRetry() throws {
        for failure in HandoverRead.allCases {
            let harness = try HandoverHarness(defaults: isolatedDefaults("fetch-\(failure)"))
            defer { try? harness.cleanUp() }
            try harness.seed()
            let before = try harness.deployedFiles()
            let handover = harness.handover(fetcher: HandoverFailingFetcher(failure: failure))
            XCTAssertFalse(harness.launch(handover).ingestionNeedsRetry)
            XCTAssertEqual(try harness.freshContext().fetchCount(FetchDescriptor<ScenarioAssignment>()), 2)
            XCTAssertEqual(harness.manifest.writes, 0)
            XCTAssertFalse(harness.defaults.bool(forKey: ScenarioHandover.doneKey))
            XCTAssertEqual(try harness.deployedFiles(), before)
            XCTAssertFalse(harness.launch().ingestionNeedsRetry)
            try harness.assertComplete()
        }
    }

    func testUnrepresentableSlugsStayOnDiskAndLogEachPair() throws {
        let harness = try HandoverHarness(defaults: isolatedDefaults())
        defer { try? harness.cleanUp() }
        let slugs = ["has space", "日本語", String(repeating: "x", count: 65)]
        for slug in slugs { try harness.seed(slug, platforms: [.codex]) }
        let before = try harness.deployedFiles()
        XCTAssertFalse(harness.launch().ingestionNeedsRetry)
        try harness.assertComplete([])
        XCTAssertEqual(harness.manifest.writes, 0)
        XCTAssertEqual(try harness.deployedFiles(), before)
        for slug in slugs {
            XCTAssertEqual(harness.logs.filter { $0 == "Left unmanaged: skill '\(slug)', agent 'codex'." }.count, 1)
        }
        XCTAssertTrue(harness.logs.contains { $0.contains("3 left unmanaged") })
    }

    func testOrphanPairIsDroppedWithoutCreatingIntent() throws {
        let harness = try HandoverHarness(defaults: isolatedDefaults())
        defer { try? harness.cleanUp() }
        harness.context.insert(ScenarioAssignment(skillID: UUID(), platform: .codex))
        try harness.context.save()
        let before = try harness.manifest.read(fromRoot: harness.root)
        XCTAssertFalse(harness.launch().ingestionNeedsRetry)
        try harness.assertComplete([])
        XCTAssertEqual(try harness.manifest.read(fromRoot: harness.root), before)
    }

    func testExistingIntentAndRealizationAreNotDuplicated() throws {
        let harness = try HandoverHarness(defaults: isolatedDefaults())
        defer { try? harness.cleanUp() }
        let skill = try harness.seed(platforms: [.codex])
        harness.context.insert(MachineDeployIntent(machineID: harness.identity.id, skillSlug: "skill", platformRaw: "codex"))
        harness.context.insert(IntentAssignment(skillID: skill.id, platformRaw: "codex"))
        harness.context.insert(ScenarioAssignment(skillID: skill.id, platform: .codex))
        try harness.context.save()
        try harness.manifest.live.write(harness.manifest.live.snapshot(from: harness.context), toRoot: harness.root)
        XCTAssertFalse(harness.launch().ingestionNeedsRetry)
        try harness.assertComplete(["codex"])
        XCTAssertEqual(harness.manifest.writes, 0)
        XCTAssertEqual(harness.nudges, 0)
    }

    func testCompletedHandoverDoesNotRunAgainAfterLocalSwitchIsTurnedOff() throws {
        let harness = try HandoverHarness(defaults: isolatedDefaults())
        defer { try? harness.cleanUp() }
        let original = try harness.seed()
        XCTAssertFalse(harness.launch().ingestionNeedsRetry)
        let fresh = harness.freshContext()
        let skill = try XCTUnwrap(try fresh.fetch(FetchDescriptor<Skill>()).first { $0.id == original.id })
        let deploys = HandoverDeployments(root: harness.root)
        let dependencies = DeployIntentDependencies.live(
            identity: harness.identity, stateService: MachineStateService(), root: harness.root,
            lockPath: harness.root + "/sync.lock", notifier: {}, reconcile: {
                IntentReconciler(platformVM: deploys.platformVM, machineIdentity: harness.identity,
                    handoverIsComplete: { false }).reconcile(context: $0)
            }
        )
        let model = DeployIntentModel(platformVM: deploys.platformVM, dependencies: dependencies)
        XCTAssertFalse(try model.set(false, skill: skill, platform: .codex, target: .userWide, context: fresh).hasFailures)
        let writes = harness.manifest.writes
        let identityCalls = harness.identity.calls
        let logs = harness.logs
        XCTAssertFalse(harness.launch().ingestionNeedsRetry)
        XCTAssertEqual(harness.manifest.writes, writes)
        XCTAssertEqual(harness.identity.calls, identityCalls)
        XCTAssertEqual(harness.logs, logs)
        XCTAssertFalse(harness.files.isSymlink(at: harness.root + "/agents/codex/skill"))
        XCTAssertEqual(try harness.manifest.read(fromRoot: harness.root).deployIntents.filter {
            $0.skillSlug == "skill" && $0.projectKey == nil
        }.map(\.platformRaw), ["cursor"])
        XCTAssertEqual(deploys.createCalls, 0)
        XCTAssertEqual(deploys.removeCalls, 1)
    }
}
