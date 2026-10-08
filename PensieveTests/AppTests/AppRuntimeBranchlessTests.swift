import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class AppRuntimeBranchlessTests: XCTestCase {
    func testBranchlessCycleReplacesHealthyTimeWithoutOfferingConnectAndDaemonAgrees() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let git = GitService()
        try git.initRepository(at: fixture.root)
        _ = try git.runOrThrow(["-C", fixture.root, "commit", "--allow-empty", "-m", "fixture"], in: nil)
        try git.setRemote("https://fixture.test/store.git", at: fixture.root)
        // A local untracked skill must not hide the branchless precondition in the daemon.
        try fixture.files.writeFile(at: fixture.root + "/skills/example/SKILL.md", content: "Body\n")
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
            defaults: isolatedDefaults(), paths: fixture.paths, gitUsabilityProbe: { .usable })
        await runtime.bootstrapTask.value
        let oldSync = Date(timeIntervalSince1970: 100)
        runtime.syncModel.apply(.synced(pushed: false, warnings: [], completedAt: oldSync))
        // The first cycle after the store loses its branch must run while eligibility still reflects
        // the earlier branch. Its app audit proves this was a real cycle, not just a configuration read.
        try fixture.files.deleteFile(at: fixture.root + "/.git/refs/heads/main")
        XCTAssertTrue(runtime.syncModel.canSyncNow)
        XCTAssertFalse(try fixture.files.entryExistsWithoutFollowingLinks(at: fixture.support + "/daemon.log"))
        let before = try fixture.snapshot()
        await runtime.syncModel.syncNowAndReport()
        let appAudit = try fixture.files.readFile(at: fixture.support + "/daemon.log")
        XCTAssertTrue(appAudit.contains("skipped branchless"))
        let model = runtime.syncModel
        XCTAssertFalse(model.canConnect)
        XCTAssertTrue(model.canSyncNow, "Sync Now can re-check a branch created outside the app")
        XCTAssertEqual(model.remoteURL, "https://fixture.test/store.git")
        XCTAssertEqual(model.lastSyncedAt, oldSync, "keep history without presenting it as current sync status")
        for hovering in [false, true] {
            let line = try XCTUnwrap(SyncFooterPresentation.make(state: model.state, canResolve: model.canResolve,
                                                                hovering: hovering, now: Date()))
            XCTAssertEqual(line.label, "Can't sync yet: the store has no branch")
            XCTAssertEqual(line.action, .sync)
        }
        await model.syncNowAndReport()
        XCTAssertEqual(model.state, .branchless, "another cycle must still report branchlessness without writes")
        XCTAssertEqual(try fixture.snapshot(), before, "the cycle cannot prepare or write a branchless store")
        let daemon = SyncDaemon(root: fixture.root, appSupport: fixture.support, git: git,
                                hasLocalBranches: { try git.hasLocalBranches(at: fixture.root) },
                                credentials: InMemoryCredentialStore(), reconciler: IngestNoopDeploy(), now: Date.init)
        XCTAssertEqual(daemon.runOnce().detail, "branchless")
        let status = try JSONDecoder().decode(DaemonStatus.self,
                                              from: fixture.files.readData(at: fixture.support + "/daemon-status.json"))
        XCTAssertEqual(status.result, "skipped")
        XCTAssertEqual(status.detail, "branchless")
        XCTAssertEqual(model.state, .branchless)
        try git.stageAllAndCommit(at: fixture.root, message: "first branch")
        await runtime.refreshGitConfiguration(probingGit: false)
        XCTAssertTrue(model.canSyncNow, "a later read of a born branch restores sync eligibility")
        XCTAssertFalse(model.canConnect)
        try await assertBranchAppearingIsNoticed()
    }

    private func assertBranchAppearingIsNoticed() async throws {
        for trigger in ["tick", "wake", "manual", "read failure"] {
            let fixture = try GitFailureFixture()
            defer { try? fixture.remove() }
            let git = GitService()
            try git.initRepository(at: fixture.root)
            try git.setRemote("https://fixture.test/store.git", at: fixture.root)
            let cycles = RuleProbe()
            let runtime = try AppRuntime(
                scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { true }),
                defaults: isolatedDefaults(), paths: fixture.paths, gitUsabilityProbe: { .usable },
                coordinatorConfigure: { coordinator in
                    await coordinator.configure(engine: StatusOrderEngine {
                        _ = cycles.run()
                        return try git.hasLocalBranches(at: fixture.root) ? .synced(pushed: false, warnings: []) : .branchless
                    }, git: git, credentials: InMemoryCredentialStore(), root: fixture.root,
                    audit: SyncAudit(appSupport: fixture.support))
                })
            await runtime.bootstrapTask.value
            runtime.scheduler.launchIngestCompleted()
            await TestWait.until(failureMessage: "branch-checking cycle did not finish") {
                !runtime.scheduler.isSyncing && !runtime.syncModel.isCycleInFlight
            }
            XCTAssertEqual(runtime.syncModel.state, .branchless)
            let before = cycles.count
            if trigger == "read failure" {
                let head = try fixture.files.readFile(at: fixture.root + "/.git/HEAD")
                try fixture.files.deleteFile(at: fixture.root + "/.git/HEAD")
                await runtime.refreshGitConfiguration(probingGit: false)
                XCTAssertNotNil(runtime.syncModel.configurationError)
                XCTAssertTrue(runtime.syncModel.canScheduleSync, "a failed read must retire the stale branch fence")
                try fixture.files.writeFile(at: fixture.root + "/.git/HEAD", content: head)
            }
            _ = try git.runOrThrow(["-C", fixture.root, "commit", "--allow-empty", "-m", "external branch"], in: nil)
            switch trigger {
            case "wake": runtime.scheduler.wake()
            case "manual": await runtime.syncModel.syncNowAndReport()
            default: runtime.scheduler.tick()
            }
            await TestWait.until(failureMessage: "branch-checking cycle did not finish") {
                !runtime.scheduler.isSyncing && !runtime.syncModel.isCycleInFlight
            }
            XCTAssertEqual(cycles.count, before + 1, trigger + " must notice a branch without a window callback")
            guard case .synced = runtime.syncModel.state else {
                XCTFail(trigger + " must replace the stale branchless status")
                continue
            }
        }
    }
}
