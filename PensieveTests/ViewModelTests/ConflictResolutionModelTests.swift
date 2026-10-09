import XCTest
import SwiftData
@testable import Pensieve

private typealias PensieveCategory = Pensieve.Category

@MainActor
final class ConflictResolutionModelTests: XCTestCase {
    private final class CallbackSpy {
        var results: [SyncCycleResult] = []
    }

    final class StubResolutionEngine: SyncEngineProtocol {
        var inspections: [ConflictInspection] = []
        var resolveOutcome: SyncOutcome = .synced(pushed: true, warnings: [])
        var resolveError: Error?
        private(set) var inspectCallCount = 0
        private(set) var resolveCallCount = 0
        private(set) var resolvedPicks: [String: ResolutionPick] = [:]

        func sync(root: String, message: String, credential: GitCredential?,
                  context: ModelContext, prepare: ((ModelContext) throws -> Void)?) throws -> SyncOutcome {
            try prepare?(context)
            return .synced(pushed: false, warnings: [])
        }

        func inspectConflicts(root: String, credential: GitCredential?,
                              context: ModelContext) throws -> ConflictInspection {
            inspectCallCount += 1
            if inspections.isEmpty { return .conflicts(ConflictSet(items: [])) }
            return inspections.removeFirst()
        }

        func resolveConflicts(root: String, picks: [String: ResolutionPick],
                              credential: GitCredential?, context: ModelContext) throws -> SyncOutcome {
            resolveCallCount += 1
            resolvedPicks = picks
            if let resolveError { throw resolveError }
            return resolveOutcome
        }
    }

    private final class StubGit: GitServiceProtocol {
        func remoteURL(at path: String) -> String? { nil }
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
        func collapseToSingleCommit(at root: String, message: String, credential: GitCredential?) throws -> Bool {
            false
        }
        func hasCommitsToPush(at path: String) -> Bool { false }
    }

    func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self,
            DeployRecord.self, PensieveCategory.self, Scenario.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    func makeModel(engine: StubResolutionEngine,
                   headStamp: @escaping () -> String? = { "before" },
                   onResolved: @escaping (SyncCycleResult) -> Void = { _ in })
        -> ConflictResolutionModel {
        ConflictResolutionModel(engine: engine, git: StubGit(),
                                credentials: InMemoryCredentialStore(), root: "/tmp/none",
                        headStamp: headStamp,
                                onResolutionStarted: { onResolved })
    }

    func testBodyAndOverlayForOneSlugGroupIntoOneSkillCard() async throws {
        let context = try makeContext()
        context.insert(Skill(name: "Deploy Helper", directoryName: "deploy-helper"))
        try context.save()
        let engine = StubResolutionEngine()
        engine.inspections = [.conflicts(ConflictSet(items: [
            bodyItem(slug: "deploy-helper"),
            overlayItem(slug: "deploy-helper")
        ]))]
        let model = makeModel(engine: engine)

        await model.loadAndReport(context: context)

        let groups = try readyGroups(from: model.phase)
        XCTAssertEqual(groups.count, 1, "body + overlay for the same slug must be one pickable group")
        XCTAssertEqual(groups[0].id, "deploy-helper")
        XCTAssertEqual(groups[0].title, "Deploy Helper")
        XCTAssertEqual(groups[0].subtitle, "Body and settings differ")
        XCTAssertEqual(groups[0].items.count, 2)
        XCTAssertFalse(model.canApply)
    }

    func testJoiningBodyAndOverlayNamesGroupWithoutLosingTheirFirstScalar() async throws {
        for scalar in PathJoiningScalars.values {
            let context = try makeContext()
            let name = PathJoiningScalars.name("skill", scalar: scalar)
            context.insert(Skill(name: "Joined Skill", directoryName: name))
            try context.save()
            let engine = StubResolutionEngine()
            engine.inspections = [.conflicts(ConflictSet(items: [bodyItem(slug: name), overlayItem(slug: name)]))]
            let model = makeModel(engine: engine)
            await model.loadAndReport(context: context)
            let groups = try readyGroups(from: model.phase)
            XCTAssertEqual(groups.count, 1)
            let group = try XCTUnwrap(groups.first)
            XCTAssertEqual(group.id, name)
            XCTAssertEqual(group.title, "Joined Skill")
            XCTAssertEqual(group.items.count, 2)
            model.choose(name, .thisMachine)
            XCTAssertTrue(model.canApply)
            await assertHistoryAction(path: "skills/" + name + "/SKILL.md", slug: name, available: true)
        }
    }

    func testChooseEnablesApply() async throws {
        let context = try makeContext()
        let engine = StubResolutionEngine()
        engine.inspections = [.conflicts(ConflictSet(items: [bodyItem(slug: "alpha")]))]
        let model = makeModel(engine: engine)

        await model.loadAndReport(context: context)
        XCTAssertFalse(model.canApply)
        model.choose("alpha", .otherMachine)

        XCTAssertTrue(model.canApply)
        let group = try XCTUnwrap(readyGroups(from: model.phase).first)
        XCTAssertEqual(group.chosen, .otherMachine)
    }

    func testApplyBuildsPicksAndFinishesDoneOnSynced() async throws {
        let context = try makeContext()
        let engine = StubResolutionEngine()
        engine.inspections = [.conflicts(ConflictSet(items: [bodyItem(slug: "alpha")]))]
        let model = makeModel(engine: engine)

        await model.loadAndReport(context: context)
        model.choose("alpha", .thisMachine)
        await model.applyAndReport(context: context)

        XCTAssertEqual(model.phase, .done)
        XCTAssertEqual(engine.resolveCallCount, 1)
        let pick = try XCTUnwrap(engine.resolvedPicks["skills/alpha/SKILL.md"])
        XCTAssertEqual(pick, ResolutionPick(side: .thisMachine, expectedThis: Data("this body".utf8),
                                            expectedOther: Data("other body".utf8)))
    }

    func testSuccessfulResolveFiresOnResolved() async throws {
        let context = try makeContext()
        let engine = StubResolutionEngine()
        let spy = CallbackSpy()
        engine.inspections = [.conflicts(ConflictSet(items: [bodyItem(slug: "alpha")]))]
        engine.resolveOutcome = .synced(
            pushed: true,
            warnings: [],
            ingestedHeadStamp: "after"
        )
        let model = makeModel(engine: engine, onResolved: { spy.results.append($0) })

        await model.loadAndReport(context: context)
        model.choose("alpha", .thisMachine)
        await model.applyAndReport(context: context)

        XCTAssertEqual(model.phase, .done)
        guard case let .synced(_, _, _, headAdvanced) = try XCTUnwrap(spy.results.first) else {
            return XCTFail("expected synced callback result")
        }
        XCTAssertTrue(headAdvanced)
    }

    func testInspectionClearedSyncFiresOnResolved() async throws {
        let context = try makeContext()
        let engine = StubResolutionEngine()
        let spy = CallbackSpy()
        engine.inspections = [.cleared(.synced(
            pushed: false,
            warnings: [],
            ingestedHeadStamp: "same"
        ))]
        let model = makeModel(
            engine: engine,
            headStamp: { "same" },
            onResolved: { spy.results.append($0) }
        )

        await model.loadAndReport(context: context)

        XCTAssertEqual(model.phase, .empty)
        guard case let .synced(_, _, _, headAdvanced) = try XCTUnwrap(spy.results.first) else {
            return XCTFail("expected synced callback result")
        }
        XCTAssertFalse(headAdvanced)
    }

    func testReinspectOutcomeDoesNotFireOnResolved() async throws {
        let context = try makeContext()
        let engine = StubResolutionEngine()
        let spy = CallbackSpy()
        engine.inspections = [.conflicts(ConflictSet(items: [bodyItem(slug: "alpha")]))]
        engine.resolveOutcome = .conflicted(["skills/alpha/SKILL.md"])
        let model = makeModel(engine: engine, onResolved: { spy.results.append($0) })

        await model.loadAndReport(context: context)
        model.choose("alpha", .otherMachine)
        await model.applyAndReport(context: context)

        XCTAssertTrue(spy.results.isEmpty)
    }

    func testConflictsChangedReinspects() async throws {
        let context = try makeContext()
        let engine = StubResolutionEngine()
        engine.inspections = [
            .conflicts(ConflictSet(items: [bodyItem(slug: "alpha")])),
            .conflicts(ConflictSet(items: [overlayItem(slug: "alpha")]))
        ]
        engine.resolveError = SyncError.conflictsChanged
        let model = makeModel(engine: engine)

        await model.loadAndReport(context: context)
        model.choose("alpha", .otherMachine)
        await model.applyAndReport(context: context)

        XCTAssertEqual(engine.inspectCallCount, 2)
        let groups = try readyGroups(from: model.phase)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].subtitle, "Settings differ")
    }

    func testUnknownSkillSlugFallsBackToSlugTitle() async throws {
        let context = try makeContext()
        let engine = StubResolutionEngine()
        engine.inspections = [.conflicts(ConflictSet(items: [bodyItem(slug: "new-skill")]))]
        let model = makeModel(engine: engine)

        await model.loadAndReport(context: context)

        let group = try XCTUnwrap(readyGroups(from: model.phase).first)
        XCTAssertEqual(group.title, "new-skill")
        let degenerate: [(String, ConflictKind)] = [
            ("skills/SKILL.md", .body), ("skills//SKILL.md", .body),
            ("skills/./SKILL.md", .body), ("skills/../SKILL.md", .body),
            ("manifest/skills/.yaml", .overlay), ("manifest/skills/", .overlay)
        ]
        context.insert(Skill(name: "Empty slug must not match", directoryName: ""))
        try context.save()
        for (path, kind) in degenerate {
            engine.inspections = [.conflicts(ConflictSet(items: [
                ConflictItem(path: path, kind: kind, thisMachine: nil, otherMachine: nil)
            ]))]
            await model.loadAndReport(context: context)
            let fallback = try XCTUnwrap(readyGroups(from: model.phase).first)
            XCTAssertEqual(fallback.id, path)
            XCTAssertEqual(fallback.title, path)
            if kind == .body { await assertHistoryAction(path: path, slug: "", available: false) }
        }
    }

    private func overlayItem(slug: String) -> ConflictItem {
        ConflictItem(path: "manifest/skills/\(slug).yaml", kind: .overlay,
                     thisMachine: Data("this overlay".utf8), otherMachine: Data("other overlay".utf8))
    }

    private func readyGroups(from phase: ConflictResolutionModel.Phase) throws
        -> [ConflictResolutionModel.ConflictGroup] {
        guard case let .ready(groups) = phase else {
            XCTFail("expected ready, got \(phase)")
            return []
        }
        return groups
    }
}
