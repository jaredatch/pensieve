import XCTest
import SwiftData
@testable import Pensieve

// Disambiguates the SwiftData `Category` model for the in-memory container schema.
private typealias PensieveCategory = Pensieve.Category

/// PLAN-08 / 08.4 — SyncModel state machine. A scriptable stub engine drives each outcome; the model must
/// pass through `.syncing` first, then map the outcome to the right terminal state (a `.conflicted` never
/// implies a successful sync; a known absent configuration remains `.unconfigured`).
@MainActor
final class SyncModelTests: XCTestCase {

    /// Returns a canned outcome (or throws) and snapshots the model's state at call time, proving
    /// `.syncing` is set BEFORE the engine runs.
    private final class StubEngine: SyncEngineProtocol {
        var outcome: SyncOutcome = .synced(pushed: true, warnings: [])
        var error: Error?
        var onCall: (() -> Void)?

        func sync(root: String, message: String, credential: GitCredential?,
                  context: ModelContext, prepare: ((ModelContext) throws -> Void)?) throws -> SyncOutcome {
            try prepare?(context)
            onCall?()
            if let error { throw error }
            return outcome
        }

        func inspectConflicts(root: String, credential: GitCredential?,
                              context: ModelContext) throws -> ConflictInspection {
            .conflicts(ConflictSet(items: []))
        }

        func resolveConflicts(root: String, picks: [String: ResolutionPick],
                              credential: GitCredential?, context: ModelContext) throws -> SyncOutcome {
            outcome
        }
    }

    /// Inert git double — only `remoteURL` matters (credential resolution); it stays nil here.
    private final class StubGit: GitServiceProtocol {
        var remote: String?
        private(set) var remoteURLCalls = 0
        func remoteURL(at path: String) -> String? {
            remoteURLCalls += 1
            return remote
        }
        func initRepository(at path: String) throws {}
        func setRemote(_ url: String, at path: String) throws {}
        func removeRemote(at path: String) throws {}
        func configuredRemoteURL(at path: String) throws -> String? { nil }
        func clone(remote: String, into path: String, credential: GitCredential?) throws {}
        func remoteHasCommits(remote: String, credential: GitCredential?) -> Bool { false }
        @discardableResult
        func stageAllAndCommit(at path: String, message: String) throws -> Bool { false }
        func preflightStoreUpdate(at path: String, credential: GitCredential?) -> FetchedStoreRevision? { nil }
        func pullRebase(at path: String, fetchedRevision: FetchedStoreRevision) throws -> PullResult {
            try pullRebase(at: path, credential: nil)
        }
        func pullRebase(at path: String, credential: GitCredential?) throws -> PullResult { .upToDate }
        func push(at path: String, credential: GitCredential?) throws {}
        func abortRebase(at path: String) throws {}
        func conflictedFiles(at path: String) -> [String] { [] }
        func blob(atStage stage: Int, path: String, in workingDir: String) -> Data? { nil }
        func continueRebase(at path: String) throws -> PullResult { .upToDate }
        func skipRebase(at path: String) throws -> PullResult { .upToDate }
        func stagePath(_ path: String, at root: String) throws {}
        func collapseToSingleCommit(at root: String, message: String, credential: GitCredential?) throws -> Bool { false }
        func hasCommitsToPush(at path: String) -> Bool { false }
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self,
            DeployRecord.self, PensieveCategory.self, Scenario.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    func testUnreadableCycleReportsAnError() {
        let model = SyncModel(git: StubGit(), root: "/tmp/none")
        model.apply(.storeUnreadable("m"))
        XCTAssertEqual(model.state, .error("m"))
    }

    private func makeModel(engine: StubEngine, model: SyncModel? = nil) -> SyncModel {
        let model = model ?? SyncModel(git: StubGit(), root: "/tmp/none")
        model.installSyncRequest {
            engine.onCall?()
            if let error = engine.error as? LocalizedError {
                model.apply(.failed(error.errorDescription ?? "Sync failed."))
                return
            }
            switch engine.outcome {
            case let .synced(pushed, warnings, _):
                model.apply(.synced(pushed: pushed, warnings: warnings, completedAt: Date()))
            case let .conflicted(paths):
                model.apply(.conflicted(paths))
            case .branchless:
                model.apply(.branchless)
            case .noRemote:
                model.apply(.noRemote)
            }
        }
        return model
    }

    func testConflictedSlugsIncludeSkillsOnly() {
        let engine = StubEngine()
        let model = SyncModel(
            git: StubGit(),
            root: "/tmp/none",
            initialState: .conflicted([
                "skills/a/SKILL.md",
                "manifest/skills/b.yaml",
                "manifest/projects.yaml"
            ])
        )
        XCTAssertEqual(model.conflictedSlugs, ["a", "b"])
        for scalar in PathJoiningScalars.values {
            let name = scalar + "skill"
            let joined = SyncModel(git: StubGit(), root: "/unused", initialState: .conflicted([
                "skills/" + name + "/SKILL.md", "manifest/skills/" + name + ".yaml"
            ]))
            XCTAssertEqual(joined.conflictedSlugs, [name])
            XCTAssertEqual(SyncEngine.kind(for: "manifest/skills/" + name + ".yaml"), .overlay)
            XCTAssertEqual(SyncEngine.kind(for: "manifest/categories/" + name + ".yaml"), .category)
        }

        let idleModel = SyncModel(
            git: StubGit(),
            root: "/tmp/none",
            initialState: .idle
        )
        XCTAssertEqual(idleModel.conflictedSlugs, [])
    }

    func testClearConflictResetsToSyncedAndClearsBadges() {
        let engine = StubEngine()
        let model = SyncModel(
            git: StubGit(),
            root: "/tmp/none",
            initialState: .conflicted(["skills/a/SKILL.md"])
        )
        XCTAssertEqual(model.conflictedSlugs, ["a"])

        model.clearConflict()

        if case .synced = model.state {
            XCTAssertTrue(model.conflictedSlugs.isEmpty)
        } else {
            XCTFail("expected .synced after clearing a conflict")
        }
    }

    func testClearConflictIsNoOpWhenNotConflicted() {
        let model = SyncModel(
            git: StubGit(),
            root: "/tmp/none",
            initialState: .idle
        )

        model.clearConflict()

        XCTAssertEqual(model.state, .idle)
    }

    func testIdleToSyncingToSynced() async throws {
        let engine = StubEngine()
        engine.outcome = .synced(pushed: true, warnings: ["update warning"])
        let model = makeModel(engine: engine)
        var duringSync: SyncModel.SyncState?
        engine.onCall = { duringSync = model.state }
        await model.syncNowAndReport(context: try makeContext())
        XCTAssertEqual(duringSync, .syncing, "state is .syncing while the engine runs")
        guard case let .synced(at) = model.state else { return XCTFail("expected .synced") }
        XCTAssertEqual(model.lastSyncedAt, at)
        XCTAssertEqual(model.lastWarnings, ["update warning"])
    }

    func testConflictedOutcomeMapsToConflictedNotSynced() async throws {
        let engine = StubEngine()
        engine.outcome = .conflicted(["skills/x/SKILL.md"])
        let model = makeModel(engine: engine)
        await model.syncNowAndReport(context: try makeContext())
        XCTAssertEqual(model.state, .conflicted(["skills/x/SKILL.md"]))
        XCTAssertNil(model.lastSyncedAt, "a conflict does not imply a successful sync/push")
    }

    func testNoRemoteOutcomeMapsToUnconfigured() async throws {
        let engine = StubEngine()
        engine.outcome = .noRemote
        let model = makeModel(engine: engine)
        let modelConfiguration = try RuntimeConfigurationFixture(model, defaults: isolatedDefaults("configuration"))
        defer { try? modelConfiguration.remove() }
        await modelConfiguration.refresh() // A read, not the cycle, establishes the absent remote.
        _ = makeModel(engine: engine, model: model) // Restore this test's cycle driver after runtime bootstrap.
        await model.syncNowAndReport(context: try makeContext())
        XCTAssertEqual(model.state, .unconfigured)
    }

    func testThrownErrorMapsToErrorState() async throws {
        let engine = StubEngine()
        engine.error = GitError.authenticationFailed(remote: "origin", detail: "denied")
        let model = makeModel(engine: engine)
        await model.syncNowAndReport(context: try makeContext())
        guard case .error = model.state else { return XCTFail("expected .error") }
    }

    /// Regression for the 2026-08-19 connect-sheet crash: `isConfigured` is read from `ContentView.body`,
    /// so it must never run git — a subprocess there pumps a nested run loop inside the render pass.
    func testIsConfiguredReadDoesNotInvokeGit() {
        let git = StubGit()
        git.remote = "git@github.com:example/skills.git"
        let model = SyncModel(git: git, root: "/tmp/none")
        for _ in 0..<3 { _ = model.isConfigured }
        XCTAssertEqual(git.remoteURLCalls, 0, "isConfigured must derive from state, never shell out")
    }

    func testIsConfiguredTracksRefreshedConfiguration() async throws {
        let git = StubGit()
        let model = SyncModel(git: git, root: "/tmp/none")
        git.remote = nil
        let modelConfiguration = try RuntimeConfigurationFixture(model, defaults: isolatedDefaults("configuration"))
        defer { try? modelConfiguration.remove() }
        await modelConfiguration.refresh()
        XCTAssertFalse(model.isConfigured, "no remote after refresh → unconfigured")
        git.remote = "git@github.com:example/skills.git"
        await modelConfiguration.refresh()
        XCTAssertTrue(model.isConfigured, "remote present after refresh → configured")
    }

    /// Layer-2 P2 (2026-08-19): with `isConfigured` state-derived, a remote that vanishes externally
    /// (repo reset while the app is open) must not leave a terminal state reporting configured forever.
    func testRefreshCorrectsVanishedRemoteFromTerminalStates() async throws {
        let initialStates: [SyncModel.SyncState] = [.synced(at: Date(timeIntervalSince1970: 100)), .error("boom")]
        for (index, initial) in initialStates.enumerated() {
            let git = StubGit()
            git.remote = nil
            let model = SyncModel(git: git, root: "/tmp/none", initialState: initial)
            let modelConfiguration = try RuntimeConfigurationFixture(model, defaults: isolatedDefaults("configuration-\(index)"))
            defer { try? modelConfiguration.remove() }
            await modelConfiguration.refresh()
            XCTAssertEqual(model.state, .unconfigured, "vanished remote must correct \(initial)")
            XCTAssertFalse(model.isConfigured)
        }
    }

    func testRefreshKeepsTerminalStatesWhenRemotePresent() async throws {
        let syncedAt = Date(timeIntervalSince1970: 100)
        let git = StubGit()
        git.remote = "git@github.com:example/skills.git"
        let model = SyncModel(git: git, root: "/tmp/none", initialState: .synced(at: syncedAt))
        let modelConfiguration = try RuntimeConfigurationFixture(model, defaults: isolatedDefaults("configuration"))
        defer { try? modelConfiguration.remove() }
        await modelConfiguration.refresh()
        XCTAssertEqual(model.state, .synced(at: syncedAt), "remote present must not disturb the synced-at display")
    }

    func testRefreshLeavesConflictedUntouchedWhenRemoteVanishes() async throws {
        let git = StubGit()
        git.remote = nil
        let model = SyncModel(git: git, root: "/tmp/none", initialState: .conflicted(["skills/x/SKILL.md"]))
        let modelConfiguration = try RuntimeConfigurationFixture(model, defaults: isolatedDefaults("configuration"))
        defer { try? modelConfiguration.remove() }
        await modelConfiguration.refresh()
        XCTAssertEqual(model.state, .conflicted(["skills/x/SKILL.md"]), "conflict UX owns this state — refresh must not clear it")
    }
}
