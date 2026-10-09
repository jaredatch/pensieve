import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class GitPoolEntryPointTests: XCTestCase {
    enum Entry: String, CaseIterable {
        case cycle, worktree, configurationProbe, configurationRemote, updateCheck, failureClassification
        case provenanceCheck, provenanceDrift, updateLoad, updateApply, updateRecheck
        case preview, previewRecheck, fetch, install, collisionAdopt, collisionRename, targetedAdopt
        case historyRead, historyProbe, historyHookedRead, historyHookedProbe

        var priority: TaskPriority {
            switch self {
            case .configurationProbe, .configurationRemote, .updateCheck, .failureClassification, .provenanceDrift:
                .utility
            default: .userInitiated
            }
        }
    }

    func testGeneratedEntryPointSweepMakesProgressDuringBlockedGit() async throws {
        for entry in Entry.allCases {
            let block = try GitBlockingFixture()
            defer { block.release(); try? block.cleanup() }
            let fixture = try UpdateReviewFixture()
            defer { try? fixture.cleanup() }
            var worker: Task<Void, Never>?
            do {
                let task = try await start(entry, block: block, fixture: fixture)
                worker = task
                let progress = await block.progress(priority: entry.priority)
                await task.value
                XCTAssertTrue(progress.blocked, "\(entry.rawValue): git must announce readiness and remain alive")
                XCTAssertTrue(progress.completed, "\(entry.rawValue): same-priority heartbeat must complete while git is blocked")
            } catch {
                block.release()
                await worker?.value
                throw error
            }
        }
    }

    private func start(_ entry: Entry, block: GitBlockingFixture,
                       fixture: UpdateReviewFixture) async throws -> Task<Void, Never> {
        switch entry {
        case .cycle, .worktree: return try await startCycle(entry, block: block, fixture: fixture)
        case .configurationProbe, .configurationRemote:
            try TestPaths.git.initRepository(at: fixture.root)
            let state = RuntimeGitState(probe: {
                if entry == .configurationProbe { try? block.run() }
                return .usable
            })
            let git = entry == .configurationRemote
                ? GitService(askpassHelperPath: TestPaths.gitAskpassHelperPath, executablePath: block.root + "/git")
                : TestPaths.git
            let model = SyncModel(git: git, root: fixture.root)
            return Task { _ = await state.refresh(probingGit: true, model: model) }
        case .updateCheck, .failureClassification:
            return try startCheck(entry, block: block, fixture: fixture)
        case .provenanceCheck, .provenanceDrift:
            let model = SkillProvenanceViewModel(driftOperation: { _, _ in try block.runAndFail() },
                checkOperation: { _, _ in try block.runAndFail() })
            let id = UUID()
            if entry == .provenanceDrift { return Task { await model.present(skillID: id, context: fixture.context) } }
            model.checkForUpdates(skillID: id, context: fixture.context)
            return Task {
                await TestWait.until(failureMessage: "provenance check did not finish") { !model.isChecking(skillID: id) }
            }
        case .updateLoad, .updateApply, .updateRecheck:
            return try startUpdate(entry, block: block, fixture: fixture)
        case .preview, .previewRecheck: return try startPreview(entry, block: block, fixture: fixture)
        case .fetch, .install, .collisionAdopt, .collisionRename, .targetedAdopt:
            return await startInstall(entry, block: block, fixture: fixture)
        case .historyRead, .historyProbe, .historyHookedRead, .historyHookedProbe:
            return startHistory(entry, block: block, fixture: fixture)
        }
    }

    private func startHistory(_ entry: Entry, block: GitBlockingFixture,
                              fixture: UpdateReviewFixture) -> Task<Void, Never> {
        let model = UpstreamHistoryViewModel(readOperation: { _, _, _ in try block.runAndFail() },
            localEditsOperation: { _, _, _ in try block.runAndFail() }, localDirectory: { _ in fixture.root })
        if entry == .historyHookedRead || entry == .historyHookedProbe {
            model.sequenceHooks = UpstreamHistorySequenceHooks(started: { _, _ in }, enter: { _ in }, finish: { _ in },
                waiting: { _ in }, resume: { _ in }, published: { _, _ in })
        }
        let id = UUID()
        let work: UpstreamHistorySequenceHooks.Work = entry == .historyRead || entry == .historyHookedRead ? .read : .probe
        let task = model.sequenceTask(work, id: id, priority: entry.priority) { try? block.run() }
        return Task { _ = await model.sequenceValue(task, id: id) }
    }

    private func startCheck(_ entry: Entry, block: GitBlockingFixture,
                            fixture: UpdateReviewFixture) throws -> Task<Void, Never> {
        let paths = try AppRuntimePaths.temporary(named: "GitPoolUpdateCheck")
        let defaults = try isolatedDefaults()
        let runtime = try AppRuntime(defaults: defaults, hostName: { nil }, paths: paths, gitUsabilityProbe: { .usable })
        return Task {
            _ = await runtime.executeUpdateCheck({ _ in
                if entry == .updateCheck { try block.runAndFail() }
                throw GitBlockingFixture.Finished.operation
            }, container: fixture.container, classifyFailure: { error in
                if entry == .failureClassification { try? block.run() }
                return ClassifiedUpdateFailure.classify(error)
            })
        }
    }

    private func startCycle(_ entry: Entry, block: GitBlockingFixture,
                            fixture: UpdateReviewFixture) async throws -> Task<Void, Never> {
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let coordinator = SyncCoordinator(modelContainer: container)
        await coordinator.configure(
            engine: entry == .cycle ? PoolSyncEngine(block: block) : NoRemotePoolEngine(),
            git: TestPaths.git,
            credentials: InMemoryCredentialStore(),
            root: fixture.root,
            audit: SyncAudit(appSupport: TestPaths.appSupportDir),
            machine: (identity: MachineIdentity(appSupportDir: TestPaths.appSupportDir), stateService: TestPaths.stateService)
        )
        let paths = AppRuntimePaths(storeRoot: fixture.root, appSupportDir: fixture.root + "/support")
        if entry == .worktree {
            let git = TestPaths.git
            try git.initRepository(at: fixture.root)
            _ = try git.runOrThrow(["config", "core.fsmonitor", block.root + "/git"], in: fixture.root)
        }
        return Task { _ = await AppRuntime.runCoordinatorCycle(coordinator, library: fixture.library, paths: paths) }
    }

    private func startUpdate(_ entry: Entry, block: GitBlockingFixture,
                             fixture: UpdateReviewFixture) throws -> Task<Void, Never> {
        let skill = try fixture.skill("update")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let model = UpdatesViewModel(rowLoader: { _ in try block.runAndFail() },
            applyOperation: { _, _, _, _, _, _ in try block.runAndFail() },
            recheckOperation: { _, _ in try block.runAndFail() })
        model.rows = [row]
        if entry == .updateLoad { return Task { await model.loadAndReport(context: fixture.context) } }
        if entry == .updateRecheck { return Task { await model.recheckAndReport(row, context: fixture.context) } }
        model.selectedSkillIDs = [row.id]
        model.loadPhase = .loaded
        return Task { await model.applySelectedAndReport(context: fixture.context) }
    }

    private func startPreview(_ entry: Entry, block: GitBlockingFixture,
                              fixture: UpdateReviewFixture) throws -> Task<Void, Never> {
        let skill = try fixture.skill("preview")
        if entry == .previewRecheck { skill.updateAvailable = false }
        let model = ViewChangesViewModel(library: fixture.library,
            operations: UpdateReviewOperations(diffOperation: { _, _ in try block.runAndFail() },
                recheckOperation: { _, _ in try block.runAndFail() }))
        model.open(skillID: skill.id, context: fixture.context)
        if entry == .previewRecheck { model.recheck(context: fixture.context) }
        return Task {
            await TestWait.until(failureMessage: "preview did not finish") {
                if case .failed = model.state { return true }; return false
            }
            model.close()
        }
    }

    private func startInstall(_ entry: Entry, block: GitBlockingFixture,
                              fixture: UpdateReviewFixture) async -> Task<Void, Never> {
        let service = PoolInstallService(block)
        let model = SkillInstallViewModel(service: service)
        model.urlText = "https://github.com/example/repository"
        if entry == .fetch {
            service.blockFetch = true
            return Task { await model.fetchAndReport() }
        }
        await model.fetchAndReport()
        if entry == .targetedAdopt {
            model.adoptTarget = SkillInstallAdoptTarget(skillID: UUID(), slug: "sample", name: "Sample")
            return Task { await model.confirmAndReport(context: fixture.context) }
        }
        if entry == .install { return Task { await model.installSelectedAndReport(context: fixture.context) } }
        model.state = .installing
        model.operationID = UUID()
        model.installContainer = fixture.container
        model.pendingCollision = SkillInstallPendingCollision(candidate: service.candidate,
            existing: SkillCollision(slug: "sample", hasDirectory: true, hasSwiftDataRow: true))
        model.collisionRenameSlug = "sample-2"
        return Task {
            if entry == .collisionAdopt { await model.adoptCollisionAndReport() } else { await model.renameCollisionAndReport() }
        }
    }
}

private struct NoRemotePoolEngine: SyncEngineProtocol {
    func sync(root: String, message: String, credential: GitCredential?, context: ModelContext,
              prepare: ((ModelContext) throws -> Void)?) throws -> SyncOutcome { .noRemote }
    func inspectConflicts(root: String, credential: GitCredential?, context: ModelContext) throws -> ConflictInspection {
        .cleared(.noRemote)
    }
    func resolveConflicts(root: String, picks: [String: ResolutionPick], credential: GitCredential?,
                          context: ModelContext) throws -> SyncOutcome { .noRemote }
}
