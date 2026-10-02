import SwiftData
import XCTest
@testable import Pensieve

/// Regression for LOG 2026-09-10T00:30:33Z: a runtime built with temp `AppRuntimePaths` must never reach the
/// developer's real store or App Support, even when the launch-ingest retry arms a manual sync trigger and the
/// scheduler drains it into a full coordinator cycle. Standalone (its own stubs) so `AppRuntimeTests.swift` stays
/// under the lint ceilings.
@MainActor
final class AppRuntimePathsTests: XCTestCase {
    private final class StubWatcher: FileWatchServiceProtocol {
        var onChange: (String) -> Void = { _ in }
        func start() -> Bool { true }
        func stop() {}
    }

    private struct StubDetection: AgentDetectionServiceProtocol {
        func isInstalled(_ platform: PlatformTarget) -> Bool { false }
        func installedPlatforms() -> [PlatformTarget] { [] }
    }

    func testProductionPathsAreTheRealOnes() {
        XCTAssertEqual(AppRuntimePaths.production.storeRoot, Constants.pensieveBaseDir)
        XCTAssertEqual(AppRuntimePaths.production.appSupportDir, PathConstants.pensieveAppSupportDir)
        XCTAssertEqual(AppRuntimePaths.production.syncLockPath, PathConstants.pensieveAppSupportDir + "/sync.lock")
    }

    func testRuntimeExposesItsSyncEngineLockToIntentSurfaces() throws {
        let paths = try AppRuntimePaths.temporary(named: "IntentLockPathTests")
        let runtime = try AppRuntime(
            defaults: isolatedDefaults(), paths: paths,
            gitUsabilityProbe: { .usable }
        )

        XCTAssertEqual(runtime.syncLockPath, paths.syncLockPath)
        XCTAssertFalse(runtime.syncLockPath.hasPrefix(paths.storeRoot + "/"))
    }

    func testTemporaryUpdateAndProvenanceOperationsUseHermeticServices() throws {
        let paths = try AppRuntimePaths.temporary(named: "UpdateOperationPathsTests")
        let updateOperations = paths.makeUpdatesViewModelOperations()
        let provenanceService = paths.makeSkillProvenanceServiceFactory()()
        let upstreamFileService = FileService()
        let upstreamHistoryService = paths.makeUpstreamHistoryService(
            fileService: upstreamFileService
        )

        try assertUpdateCheckService(provenanceService, paths: paths, usesMemoryCredentials: true)
        try assertUpdateCheckService(
            updateOperations.updateCheckService,
            paths: paths,
            usesMemoryCredentials: true
        )
        try assertUpstreamHistoryService(
            upstreamHistoryService,
            paths: paths,
            usesMemoryCredentials: true,
            expectedFileService: upstreamFileService
        )
        assertSkillInstallService(
            updateOperations.skillInstallService,
            paths: paths,
            usesMemoryCredentials: true
        )
    }

    func testProductionUpdateAndProvenanceOperationsMatchServiceDefaults() throws {
        let paths = AppRuntimePaths.production
        let updateOperations = paths.makeUpdatesViewModelOperations()
        let provenanceService = paths.makeSkillProvenanceServiceFactory()()
        let upstreamFileService = FileService()
        let upstreamHistoryService = paths.makeUpstreamHistoryService(
            fileService: upstreamFileService
        )

        try assertUpdateCheckService(provenanceService, paths: paths, usesMemoryCredentials: false)
        try assertUpdateCheckService(
            updateOperations.updateCheckService,
            paths: paths,
            usesMemoryCredentials: false
        )
        try assertUpstreamHistoryService(
            upstreamHistoryService,
            paths: paths,
            usesMemoryCredentials: false,
            expectedFileService: upstreamFileService
        )
        assertSkillInstallService(
            updateOperations.skillInstallService,
            paths: paths,
            usesMemoryCredentials: false
        )
        XCTAssertEqual(UpdateCheckService.defaultScratchRoot, paths.appSupportDir + "/update-check-scratch")
        XCTAssertEqual(SkillInstallService.defaultScratchRoot, paths.appSupportDir + "/skill-install-scratch")
    }

    func testHistoryCacheUsesInjectedAppSupportOutsideStoreAndScratch() throws {
        let paths = try AppRuntimePaths.temporary(named: "HistoryCachePathTests")
        let history = paths.makeUpstreamHistoryViewModel()

        XCTAssertEqual(history.cache?.directory, paths.appSupportDir + "/upstream-history-cache")
        XCTAssertFalse(try XCTUnwrap(history.cache?.directory).hasPrefix(paths.storeRoot + "/"))
        XCTAssertFalse(try XCTUnwrap(history.cache?.directory).hasPrefix(
            paths.appSupportDir + "/upstream-history-scratch/"
        ))
    }

    /// Layer-2 of the bounded task: a runtime built on temp paths must not write its launch markers into
    /// the app's real preferences domain either (`.standard` in the test host IS the app's domain).
    func testTemporaryPathsGetTheirOwnDefaultsSuite() throws {
        XCTAssertTrue(try AppRuntimePaths.production.makeDefaults() === UserDefaults.standard)

        let defaults = try AppRuntimePaths.temporary(named: "AppRuntimePathsTests").makeDefaults()
        let key = "hermetic-probe-\(UUID().uuidString)"
        defaults.set(true, forKey: key)

        XCTAssertFalse(defaults === UserDefaults.standard)
        XCTAssertTrue(defaults.bool(forKey: key))
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
    }

    func testRetryDrivenSyncCycleTouchesOnlyTheInjectedPaths() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let paths = fixture.paths
        // A configured unborn repository passes the scheduler gate, then stops before store writes or network I/O.
        try GitService().initRepository(at: paths.storeRoot)
        try GitService().setRemote("https://fixture.test/store.git", at: paths.storeRoot)
        let before = try fixture.snapshot()
        let container = try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let defaults = try isolatedDefaults()
        var returnedInitialOutcome = false
        let runtime = try AppRuntime(
            container: container,
            platformVM: PlatformViewModel(agentDetection: StubDetection(), deployStateStore: .memoryBacked),
            library: paths.makeLibrary(fileWatchService: StubWatcher(), notifier: {}),
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { true }),
            defaults: defaults,
            launchReconcile: { _, _ in
                defer { returnedInitialOutcome = true }
                return returnedInitialOutcome
                    ? LaunchReconcileOutcome(rebuild: RebuildResult(), migrationRan: false, ingestedHeadStamp: "stable")
                    : LaunchReconcileOutcome(
                        rebuild: RebuildResult(), migrationRan: false, ingestedHeadStamp: nil, ingestionNeedsRetry: true
                    )
            },
            launchBackfill: { _ in },
            launchIngestRetryNanoseconds: 10_000_000,
            paths: paths,
            gitUsabilityProbe: { .usable }
        )
        runtime.performLaunchWorkIfNeeded(context: ModelContext(container))

        let auditPath = paths.appSupportDir + "/daemon.log"
        let audit = try await waitForRetryCycle(runtime, auditPath: auditPath)

        XCTAssertFalse(runtime.syncModel.isCycleInFlight, "the model cycle must finish before inspecting its paths")
        XCTAssertFalse(runtime.scheduler.isSyncing, "the retry-driven cycle must finish before inspecting its paths")
        XCTAssertTrue(audit.contains("skipped noRemote"), "the cycle ran against the injected App Support: \(audit)")
        XCTAssertFalse(try fixture.files.entryExistsWithoutFollowingLinks(at: paths.storeRoot + "/manifest"))
        XCTAssertEqual(try fixture.snapshot(), before, "the cycle must preserve all store entries and bytes, including .git")
    }

    func testPathSnapshotWaitIncludesModelCycleAfterScheduledFollowUpQueues() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try GitService().initRepository(at: fixture.root)
        try GitService().setRemote("https://fixture.test/store.git", at: fixture.root)
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { true }),
            defaults: isolatedDefaults(), paths: fixture.paths, gitUsabilityProbe: { .usable }
        )
        await runtime.bootstrapTask.value
        let started = expectation(description: "model cycle started")
        var release: CheckedContinuation<Void, Never>?
        var first = true
        runtime.syncModel.installSyncRequest {
            if first {
                first = false
                await withCheckedContinuation { continuation in
                    release = continuation
                    started.fulfill()
                }
            }
            runtime.syncModel.apply(.noRemote)
        }
        let cycle = Task { await runtime.syncModel.syncNowAndReport() }
        await fulfillment(of: [started], timeout: 2)
        runtime.scheduler.launchIngestCompleted()
        await TestWait.until(failureMessage: "scheduler did not queue its follow-up") {
            !runtime.scheduler.isSyncing && !runtime.scheduler.hasPendingTrigger
        }
        XCTAssertEqual(runtime.syncModel.state, .syncing)
        let auditPath = fixture.support + "/daemon.log"
        try fixture.files.writeFile(at: auditPath, content: "skipped noRemote\n")
        var returned = false
        let waiter = Task {
            _ = try await waitForRetryCycle(runtime, auditPath: auditPath)
            returned = true
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(returned, "scheduler completion does not finish the model's in-flight cycle")
        release?.resume()
        await cycle.value
        try await waiter.value
        XCTAssertTrue(returned)
    }

    private func waitForRetryCycle(_ runtime: AppRuntime, auditPath: String) async throws -> String {
        var audit = ""
        // The audit precedes the runtime's final git status, which briefly creates .git/index.lock.
        // The scheduler can finish while a model cycle queues a follow-up. Wait for the model itself too.
        for _ in 0..<60 where !audit.contains("noRemote") || runtime.syncModel.isCycleInFlight || runtime.scheduler.isSyncing {
            try await Task.sleep(nanoseconds: 50_000_000)
            audit = (try? String(contentsOfFile: auditPath, encoding: .utf8)) ?? ""
        }

        return audit
    }

    private func assertUpdateCheckService(
        _ service: UpdateCheckService,
        paths: AppRuntimePaths,
        usesMemoryCredentials: Bool
    ) throws {
        XCTAssertEqual(service.storeRoot, paths.storeRoot)
        XCTAssertEqual(service.scratchRoot, paths.appSupportDir + "/update-check-scratch")
        assertCredentialStore(service.credentialStore, usesMemoryCredentials: usesMemoryCredentials)
        let contentHasher = try XCTUnwrap(service.contentHasher as? SkillInstallService)
        assertSkillInstallService(
            contentHasher,
            paths: paths,
            usesMemoryCredentials: usesMemoryCredentials
        )
    }

    private func assertSkillInstallService(
        _ service: SkillInstallService,
        paths: AppRuntimePaths,
        usesMemoryCredentials: Bool
    ) {
        XCTAssertEqual(service.storeRoot, paths.storeRoot)
        XCTAssertEqual(service.scratchRoot, paths.appSupportDir + "/skill-install-scratch")
        XCTAssertEqual(service.lockPath, paths.syncLockPath)
        assertCredentialStore(service.credentialStore, usesMemoryCredentials: usesMemoryCredentials)
    }

    private func assertUpstreamHistoryService(
        _ service: UpstreamHistoryService,
        paths: AppRuntimePaths,
        usesMemoryCredentials: Bool,
        expectedFileService: FileService
    ) throws {
        XCTAssertEqual(service.scratchRoot, paths.appSupportDir + "/upstream-history-scratch")
        assertCredentialStore(service.credentialStore, usesMemoryCredentials: usesMemoryCredentials)
        let serviceFileService = try XCTUnwrap(service.fileService as? FileService)
        XCTAssertTrue(serviceFileService === expectedFileService)
        let contentHasher = try XCTUnwrap(service.contentHasher as? SkillInstallService)
        let hasherFileService = try XCTUnwrap(contentHasher.fileService as? FileService)
        XCTAssertTrue(hasherFileService === expectedFileService)
        assertSkillInstallService(
            contentHasher,
            paths: paths,
            usesMemoryCredentials: usesMemoryCredentials
        )
    }

    private func assertCredentialStore(
        _ store: CredentialStoreProtocol,
        usesMemoryCredentials: Bool
    ) {
        if usesMemoryCredentials {
            XCTAssertTrue(store is InMemoryCredentialStore)
        } else {
            XCTAssertTrue(store is KeychainCredentialStore)
        }
    }
}
