import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class StoreUnreadableFenceTests: XCTestCase {
    private var tempDir: String!
    private var library: SkillLibraryViewModel!

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.path + "PensieveFenceTests-" + UUID().uuidString
        try FileService().createDirectory(at: tempDir)
        library = SkillLibraryViewModel(
            skillStore: SkillStore(fileService: FileService(), baseDir: tempDir, storeRoot: tempDir),
            fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir), manifestRoot: TestPaths.storeRoot
        )
    }

    override func tearDownWithError() throws {
        if let tempDir, FileService().directoryExists(at: tempDir) {
            try FileService().deleteDirectory(at: tempDir)
        }
    }

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        ))
    }

    private func makeRuntime(label: String, outcome: LaunchReconcileOutcome) throws -> AppRuntime {
        let library = SkillLibraryViewModel(
            skillStore: SkillStore(fileService: FileService(), baseDir: tempDir,
                storeRoot: tempDir), fileWatchService: FenceStubWatcher(),
            manifestRoot: TestPaths.storeRoot
        )
        return try AppRuntime(
            container: try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true)),
            library: library, defaults: isolatedDefaults(label),
            launchReconcile: { _, _ in outcome },
            launchBackfill: { _ in },
            paths: try AppRuntimePaths.temporary(named: "StoreUnreadableFenceTests"),
            gitUsabilityProbe: { .usable }
        )
    }

    func testLaunchVerdictSetsAndClearsTheFence() {
        library.setStoreUnreadable(true)
        XCTAssertTrue(library.storeUnreadable)
        XCTAssertTrue(library.addsFenced)
        XCTAssertFalse(library.libraryUnavailable)

        library.setStoreUnreadable(false)
        XCTAssertFalse(library.storeUnreadable)
        XCTAssertFalse(library.addsFenced)
    }

    func testCyclesPastThePreWriteReadLiftTheFenceAndAnUnreadableCycleDropsIt() {
        library.setStoreUnreadable(true)
        library.applySyncCycleOutcome(.synced(pushed: false, warnings: [], completedAt: Date()))
        XCTAssertFalse(library.storeUnreadable)

        library.applySyncCycleOutcome(.storeUnreadable("x"))
        XCTAssertTrue(library.storeUnreadable)

        library.applySyncCycleOutcome(.conflicted(["a"]))
        XCTAssertFalse(library.storeUnreadable)
    }

    func testRisingFenceClosesTheCreateSheet() {
        library.showCreateSheet = true
        library.setStoreUnreadable(true)
        XCTAssertFalse(library.showCreateSheet)

        library.setStoreUnreadable(false)
        library.showCreateSheet = true
        library.applySyncCycleOutcome(.storeUnreadable("x"))
        XCTAssertFalse(library.showCreateSheet)

        library.showCreateSheet = true
        library.applySyncCycleOutcome(.synced(pushed: false, warnings: [], completedAt: Date()))
        XCTAssertTrue(library.showCreateSheet)
    }

    func testOtherCycleOutcomesLeaveTheFenceAlone() {
        let outcomes: [SyncCycleResult] = [.noRemote, .locked, .failed("x")]
        for outcome in outcomes {
            library.setStoreUnreadable(true)
            library.applySyncCycleOutcome(outcome)
            XCTAssertTrue(library.storeUnreadable)

            library.setStoreUnreadable(false)
            library.applySyncCycleOutcome(outcome)
            XCTAssertFalse(library.storeUnreadable)
        }
    }

    func testUnreadableLaunchOutcomeFencesAddsAndSuppressesTheWizard() throws {
        var rebuild = RebuildResult()
        rebuild.storeUnreadable = true
        let runtime = try makeRuntime(label: "unreadable",
            outcome: LaunchReconcileOutcome(rebuild: rebuild, migrationRan: false)
        )
        XCTAssertTrue(runtime.performLaunchWorkIfNeeded(context: ModelContext(runtime.container)))
        XCTAssertTrue(runtime.library.storeUnreadable)
        XCTAssertTrue(runtime.library.addsFenced)
        XCTAssertFalse(runtime.storeQuarantined)
        XCTAssertFalse(runtime.shouldAutoShowImportWizard(skillCount: 0))
        XCTAssertFalse(AppRuntime.shouldAutoShowImportWizard(
            skillCount: 0, storeQuarantined: false, storeUnreadable: true
        ))
        XCTAssertTrue(AppRuntime.shouldAutoShowImportWizard(
            skillCount: 0, storeQuarantined: false, storeUnreadable: false
        ))

        runtime.backgroundSyncEnabled = false
        let readableRuntime = try makeRuntime(label: "readable",
            outcome: LaunchReconcileOutcome(rebuild: RebuildResult(), migrationRan: false)
        )
        XCTAssertTrue(readableRuntime.performLaunchWorkIfNeeded(context: ModelContext(readableRuntime.container)))
        XCTAssertFalse(runtime.backgroundSyncEnabled, "another runtime must not clear the first runtime defaults")
        XCTAssertFalse(readableRuntime.library.storeUnreadable)
        XCTAssertTrue(readableRuntime.shouldAutoShowImportWizard(skillCount: 0))
    }

    func testEngineRefusingTheStoreYieldsTheTypedOutcome() async throws {
        let container = try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let coordinator = await Task.detached { SyncCoordinator(modelContainer: container) }.value
        await coordinator.configure(
            engine: UnreadableStoreEngine(),
            git: TestPaths.git,
            credentials: InMemoryCredentialStore(),
            root: tempDir,
            audit: FenceNullAudit(),
            machine: (identity: InertMachineIdentity(), stateService: InertMachineStateService())
        )

        let result = await coordinator.runCycle()
        XCTAssertEqual(
            result,
            .storeUnreadable(SyncError.storeUnreadable(["w"]).errorDescription ?? "")
        )
        XCTAssertEqual(result.auditFields.category, "failed")
        XCTAssertEqual(result.auditFields.detail, "storeUnreadable")
    }

    func testCreateSkillRefusesWhileFenced() throws {
        let context = try makeContext()
        library.setStoreUnreadable(true)
        XCTAssertNil(library.createSkill(
            name: "Fenced", description: "", body: "# b", tags: [], context: context
        ))
        XCTAssertEqual(library.error, SkillLibraryViewModel.storeUnreadableMessage)
        XCTAssertFalse(FileService().directoryExists(at: tempDir + "/fenced"))
        XCTAssertTrue(try context.fetch(FetchDescriptor<Skill>()).isEmpty)

        library.setStoreUnreadable(false)
        library.createSkill(
            name: "Fenced", description: "", body: "# b", tags: [], context: context
        )
        XCTAssertTrue(FileService().directoryExists(at: tempDir + "/fenced"))
        XCTAssertEqual(try context.fetch(FetchDescriptor<Skill>()).count, 1)
    }
}

private final class FenceStubWatcher: FileWatchServiceProtocol {
    var onChange: (String) -> Void = { _ in }
    func start() -> Bool { true }
    func stop() {}
}

private struct FenceNullAudit: SyncAuditWriting {
    func record(category: String, detail: String) {}
}

private struct UnreadableStoreEngine: SyncEngineProtocol {
    func sync(root: String, message: String, credential: GitCredential?, context: ModelContext,
              prepare: ((ModelContext) throws -> Void)?) throws -> SyncOutcome {
        throw SyncError.storeUnreadable(["w"])
    }

    func inspectConflicts(root: String, credential: GitCredential?, context: ModelContext) throws -> ConflictInspection {
        fatalError("unused")
    }

    func resolveConflicts(root: String, picks: [String: ResolutionPick], credential: GitCredential?,
                          context: ModelContext) throws -> SyncOutcome {
        fatalError("unused")
    }
}
