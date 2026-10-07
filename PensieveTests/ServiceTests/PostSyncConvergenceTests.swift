import Foundation
import SwiftData
import XCTest
@testable import Pensieve

private typealias ConvergenceCategory = Pensieve.Category

@MainActor
final class PostSyncConvergenceTests: XCTestCase {
    private var tempDir = ""

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.url
            .appendingPathComponent("PensievePostSyncConvergence-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if !tempDir.isEmpty { try? FileManager.default.removeItem(atPath: tempDir) }
    }

    func testUpToDateCycleRunsDeployReconciler() throws {
        let harness = try makeHarness()
        harness.component.run(after: syncedResult())
        XCTAssertEqual(harness.recorder.events, ["deploy"])
    }

    func testHeadAdvanceRunsLedgerReconcilersInOrder() throws {
        let harness = try makeHarness()
        harness.component.run(after: syncedResult(headAdvanced: true))
        XCTAssertEqual(harness.recorder.events, ["deploy", "category", "intent"])
        XCTAssertEqual(Set(harness.recorder.contexts).count, 1, "one fresh context serves the ordered pass")
    }

    func testHeadUnchangedSkipsLedgerReconcilers() throws {
        let harness = try makeHarness()
        harness.component.run(after: syncedResult())
        XCTAssertEqual(harness.recorder.events, ["deploy"])
        XCTAssertTrue(harness.recorder.contexts.isEmpty)
    }

    func testLaunchIngestRunsFullConvergencePass() throws {
        let harness = try makeHarness()
        harness.component.runAfterLaunchIngest()
        XCTAssertEqual(harness.recorder.events, ["deploy", "category", "intent"])
        XCTAssertEqual(Set(harness.recorder.contexts).count, 1)
    }

    func testConflictedRunsNothing() throws {
        let harness = try makeHarness()
        harness.component.run(after: .conflicted(["skills/example/SKILL.md"]))
        XCTAssertTrue(harness.recorder.events.isEmpty)
        XCTAssertTrue(harness.recorder.contexts.isEmpty)
    }

    func testDidConvergeFiresAfterSuccessfulCyclesOnly() throws {
        let container = try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let recorder = ConvergenceRecorder()
        var count = 0
        var eventCounts: [Int] = []
        let component = PostSyncConvergence(
            root: tempDir,
            deployReconciler: ConvergenceRecordingDeploy(recorder: recorder),
            contextFactory: { ModelContext(container) },
            categoryReconciler: ConvergenceRecordingLedger(name: "category", recorder: recorder),
            intentReconciler: ConvergenceRecordingLedger(name: "intent", recorder: recorder),
            auditLog: { _, _ in },
            didConverge: {
                count += 1
                eventCounts.append(recorder.events.count)
            }
        )

        component.run(after: syncedResult(headAdvanced: false))
        XCTAssertEqual(count, 1)
        component.runAfterLaunchIngest()
        XCTAssertEqual(count, 2)
        component.run(after: .conflicted(["skills/example/SKILL.md"]))
        XCTAssertEqual(count, 2)
        XCTAssertEqual(eventCounts, [1, 4], "deploy must be recorded before the convergence hook fires")
    }

    func testConvergenceUsesFreshContext() throws {
        let container = try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let uiContext = ModelContext(container)
        let category = ConvergenceCategory(name: "Before")
        uiContext.insert(category)
        try uiContext.save()
        let registered = try XCTUnwrap(uiContext.fetch(FetchDescriptor<ConvergenceCategory>()).first)

        let sibling = ModelContext(container)
        let siblingCategory = try XCTUnwrap(sibling.fetch(FetchDescriptor<ConvergenceCategory>()).first)
        siblingCategory.name = "After"
        try sibling.save()

        let recorder = ConvergenceRecorder()
        let categoryReconciler = ConvergenceRecordingLedger(name: "category", recorder: recorder)
        let intentReconciler = ConvergenceRecordingLedger(name: "intent", recorder: recorder)
        let component = PostSyncConvergence(
            root: tempDir,
            deployReconciler: ConvergenceRecordingDeploy(recorder: recorder),
            contextFactory: { ModelContext(container) },
            categoryReconciler: categoryReconciler,
            intentReconciler: intentReconciler,
            auditLog: { _, _ in }
        )
        component.run(after: syncedResult(headAdvanced: true))

        XCTAssertEqual(registered.name, "Before", "the UI context must exercise registered-object staleness")
        XCTAssertEqual(recorder.observedCategoryNames, ["After"])
        XCTAssertFalse(recorder.contexts.contains(ObjectIdentifier(uiContext)))
    }

    func testRemoteDeletionPrunesDanglingRecordedLink() throws {
        let fileService = FileService()
        let skillsRoot = tempDir + "/store/skills"
        let agentRoot = tempDir + "/agent/skills"
        let appSupport = tempDir + "/app-support"
        try fileService.createDirectory(at: skillsRoot)
        try fileService.createDirectory(at: agentRoot)
        let target = skillsRoot + "/deleted"
        try fileService.createDirectory(at: target)
        let link = agentRoot + "/deleted"
        try fileService.createSymlink(at: link, pointingTo: target)
        try fileService.deleteDirectory(at: target)

        let deployState = DeployStateStore(fileService: fileService, appSupportDir: appSupport)
        try deployState.upsert(DeployStateRecord(
            slug: "deleted",
            platform: PlatformTarget.claudeCode.rawValue,
            scope: "user",
            projectIdentityKey: nil,
            artifactPath: link,
            recordedAt: "2026-08-15T00:00:00Z"
        ))
        let deploy = DeployReconciler(
            fileService: fileService,
            deployState: deployState,
            pensieveSkillsDir: skillsRoot,
            agentSkillDirs: [.init(platform: .claudeCode, path: agentRoot)],
            cursorRulesDir: tempDir + "/cursor"
        )
        let container = try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let recorder = ConvergenceRecorder()
        let ledger = ConvergenceRecordingLedger(name: "unused", recorder: recorder)
        let component = PostSyncConvergence(
            root: tempDir,
            deployReconciler: deploy,
            contextFactory: { ModelContext(container) },
            categoryReconciler: ledger,
            intentReconciler: ledger,
            auditLog: { _, _ in }
        )

        component.run(after: syncedResult())
        XCTAssertFalse(fileService.isSymlink(at: link))
        XCTAssertTrue(try deployState.read().records.isEmpty)
    }

    private struct Harness {
        let component: PostSyncConvergence
        let recorder: ConvergenceRecorder
    }

    private func makeHarness() throws -> Harness {
        let container = try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let recorder = ConvergenceRecorder()
        let component = PostSyncConvergence(
            root: tempDir,
            deployReconciler: ConvergenceRecordingDeploy(recorder: recorder),
            contextFactory: { ModelContext(container) },
            categoryReconciler: ConvergenceRecordingLedger(name: "category", recorder: recorder),
            intentReconciler: ConvergenceRecordingLedger(name: "intent", recorder: recorder),
            auditLog: { _, _ in }
        )
        return Harness(component: component, recorder: recorder)
    }

    private func syncedResult(headAdvanced: Bool = false) -> SyncCycleResult {
        .synced(pushed: false, warnings: [], completedAt: Date(), headAdvanced: headAdvanced)
    }
}
