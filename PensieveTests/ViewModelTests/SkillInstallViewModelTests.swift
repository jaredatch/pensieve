import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class SkillInstallViewModelTests: XCTestCase {
    var tempDir: String!
    var fileService: FileService!

    override func setUpWithError() throws {
        tempDir = NSTemporaryDirectory() + "PensieveSkillInstallViewModelTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        fileService = FileService()
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    func testFixtureRepositoryInstallsSelectedSkillsEndToEnd() async throws {
        let repository = try makeRepository(named: "fixture")
        try writeSkill("skills/alpha", name: "Alpha", description: "First", in: repository)
        try writeSkill("skills/beta", name: "Beta", description: "Second", in: repository)
        try commit(repository)
        let container = try makeContainer()
        let service = makeRealService()
        let model = makeModel(service: service, repository: repository)
        model.urlText = "fixture"

        await model.fetchAndReport()
        XCTAssertEqual(model.state, .picking)
        XCTAssertEqual(model.selectedCount, 2)

        await model.installSelectedAndReport(context: ModelContext(container))

        XCTAssertEqual(model.state, .done)
        XCTAssertEqual(model.reports.count, 2)
        let verificationContext = ModelContext(container)
        XCTAssertEqual(try verificationContext.fetch(FetchDescriptor<Skill>()).count, 2)
        XCTAssertTrue(fileService.fileExists(at: tempDir + "/store/skills/alpha/SKILL.md"))
        XCTAssertTrue(fileService.fileExists(at: tempDir + "/store/skills/beta/SKILL.md"))
    }

    func testCollisionResolvesAdoptRenameSkip() async throws {
        let candidates = [candidate("adopt"), candidate("rename"), candidate("skip")]
        let stub = ScriptedInstallService(candidates: candidates)
        stub.collisionSlugs = Set(candidates.map(\.slug))
        let model = makeModel(service: stub)
        let context = ModelContext(try makeContainer())
        model.urlText = "fixture"
        await model.fetchAndReport()

        await model.installSelectedAndReport(context: context)
        XCTAssertEqual(model.pendingCollision?.candidate.slug, "adopt")
        XCTAssertEqual(model.pendingCollision?.canAdopt, true)
        XCTAssertFalse(SkillInstallPendingCollision(
            candidate: candidates[0],
            existing: SkillCollision(slug: "partial", hasDirectory: true, hasSwiftDataRow: false)
        ).canAdopt)

        await model.adoptCollisionAndReport()
        XCTAssertEqual(model.pendingCollision?.candidate.slug, "rename")

        model.collisionRenameSlug = "rename-2"
        await model.renameCollisionAndReport()
        XCTAssertEqual(model.pendingCollision?.candidate.slug, "skip")

        await model.skipCollisionAndReport()

        XCTAssertEqual(model.state, .done)
        XCTAssertEqual(stub.adoptedSlugs, ["adopt"])
        XCTAssertEqual(stub.renamedSlugs, ["rename-2"])
        XCTAssertEqual(model.reports.map(\.result), [
            .adopted(localDrift: false),
            .installed(slug: "rename-2"),
            .skipped
        ])
    }

    func testLiveParseAndTargetedLinkSkipPicker() async {
        let candidate = candidate("target")
        let stub = ScriptedInstallService(candidates: [candidate])
        let model = SkillInstallViewModel(service: stub)

        model.urlText = "https://example.com/not-github"
        XCTAssertNil(model.parsedURL)
        XCTAssertEqual(model.urlRejectionReason, "not a supported GitHub URL")

        model.urlText = "https://github.com/acme/skills/tree/main/skills/target"
        XCTAssertNil(model.urlRejectionReason)
        await model.fetchAndReport()

        XCTAssertEqual(model.state, .picking)
        XCTAssertTrue(model.isTargetedConfirmation)
        XCTAssertTrue(model.isSelected(candidate))
    }

    func testUnavailableCandidateRemainsVisibleAndUnselected() async {
        let unavailable = SkillCandidate(
            path: "skills/broken",
            slug: "broken",
            name: "Broken",
            skillDescription: nil,
            treeHash: "tree-broken",
            containsSymlink: false,
            unavailableReason: "missing description"
        )
        let model = makeModel(service: ScriptedInstallService(candidates: [unavailable]))
        model.urlText = "fixture"

        await model.fetchAndReport()

        XCTAssertEqual(model.candidates, [unavailable])
        XCTAssertEqual(model.selectedCount, 0)
        XCTAssertFalse(model.canInstall)
    }

    func testCancelMidFetchIgnoresLateResult() async throws {
        let stub = ScriptedInstallService(candidates: [candidate("late")])
        stub.fetchGate = TestWait.Gate(owner: self)
        let model = makeModel(service: stub)
        model.urlText = "fixture"
        model.fetch()
        let fetchTask = try XCTUnwrap(model.operationTask)
        let started = await TestWait.forSemaphore(stub.fetchStarted)
        XCTAssertTrue(started, "skill fetch did not start")

        model.cancel()
        XCTAssertEqual(model.state, .idle)
        stub.fetchGate?.open()
        await TestWait.forTask(fetchTask, failureMessage: "cancelled skill fetch did not finish")

        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.source)
    }

    func testOneInstallFailureDoesNotAbortRemainingSkills() async throws {
        let stub = ScriptedInstallService(candidates: [candidate("bad"), candidate("good")])
        stub.failingSlugs = ["bad"]
        let model = makeModel(service: stub)
        model.urlText = "fixture"
        await model.fetchAndReport()

        await model.installSelectedAndReport(context: ModelContext(try makeContainer()))

        XCTAssertEqual(model.state, .done)
        XCTAssertEqual(model.reports.count, 2)
        guard case .failed = model.reports[0].result else {
            return XCTFail("first skill should report its failure")
        }
        XCTAssertEqual(model.reports[1].result, .installed(slug: "good"))
        XCTAssertFalse(stub.fetchedOnMainThread)
        XCTAssertFalse(stub.installedOnMainThread)
    }

    func testDoubleSubmitPreventedWhileInstalling() async throws {
        let stub = ScriptedInstallService(candidates: [candidate("slow")])
        stub.installGate = TestWait.Gate(owner: self)
        let model = makeModel(service: stub)
        model.urlText = "fixture"
        await model.fetchAndReport()
        let context = ModelContext(try makeContainer())

        model.installSelected(context: context)
        let installStarted = await TestWait.forSemaphore(stub.installStarted)
        XCTAssertTrue(installStarted, "skill install did not start")
        model.installSelected(context: context)
        XCTAssertEqual(stub.installCallCount, 1)

        stub.installGate?.open()
        await TestWait.until(failureMessage: "skill install did not finish") {
            model.state == .done
        }
        XCTAssertEqual(stub.installCallCount, 1)
    }

    func testRenameCollisionCreatesNewDirectoryWithoutClobberingExistingSkill() async throws {
        let repository = try makeRepository(named: "rename-fixture")
        try writeSkill("skills/open-skill", name: "Open Skill", description: "Upstream", in: repository)
        try commit(repository)
        let storeRoot = tempDir + "/store"
        try fileService.writeFile(
            at: storeRoot + "/skills/open-skill/SKILL.md",
            content: "---\nname: Local\ndescription: Local copy\n---\nkeep me\n"
        )
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Skill(name: "Local", skillDescription: "Local copy", directoryName: "open-skill"))
        try context.save()
        let model = makeModel(service: makeRealService(), repository: repository)
        model.urlText = "fixture"
        await model.fetchAndReport()

        await model.installSelectedAndReport(context: context)
        XCTAssertEqual(model.pendingCollision?.existing.slug, "open-skill")
        model.collisionRenameSlug = "open-skill-2"
        await model.renameCollisionAndReport()

        XCTAssertEqual(model.state, .done)
        XCTAssertTrue(fileService.fileExists(at: storeRoot + "/skills/open-skill-2/SKILL.md"))
        XCTAssertTrue(try fileService.readFile(at: storeRoot + "/skills/open-skill/SKILL.md")
            .contains("keep me"))
    }

    func testGenericCollisionAdoptRecordsCompletion() async throws {
        let repository = try makeRepository(named: "adopt-fixture")
        try writeSkill("skills/adopted", name: "Adopted", description: "Upstream", in: repository)
        try commit(repository)
        let storeRoot = tempDir + "/store"
        try fileService.writeFile(
            at: storeRoot + "/skills/adopted/SKILL.md",
            content: "---\nname: Adopted\ndescription: Local copy\n---\nlocal edits\n"
        )
        let container = try makeContainer()
        let context = ModelContext(container)
        let existing = Skill(
            name: "Adopted",
            skillDescription: "Local copy",
            directoryName: "adopted"
        )
        context.insert(existing)
        try context.save()
        let model = makeModel(service: makeRealService(), repository: repository)
        model.urlText = "fixture"
        await model.fetchAndReport()

        await model.installSelectedAndReport(context: context)
        XCTAssertEqual(model.pendingCollision?.existing.slug, "adopted")
        await model.adoptCollisionAndReport()

        XCTAssertEqual(model.state, .done)
        XCTAssertEqual(model.completedAdoptions.count, 1)
        XCTAssertEqual(model.completedAdoptions.first?.skillID, existing.id)
        XCTAssertEqual(model.completedAdoptions.first?.localDrift, true)
    }

    func testCanceledTaskNeverEntersServiceCall() async throws {
        let stub = ScriptedInstallService(candidates: [candidate("never")])
        let source = SkillFetchResult(
            repo: "/fixture", ref: "main", headCommit: "head", candidates: stub.candidates
        )
        let container = try makeContainer()
        let gate = TestWait.Gate(owner: self)
        let task = Task.detached {
            try gate.wait()
            return try SkillInstallViewModel.performUnlessCancelled { () throws -> SkillInstallResult in
                let context = ModelContext(container)
                return try stub.install(
                    candidate: stub.candidates[0], from: source, credential: nil, context: context
                )
            }
        }

        task.cancel()
        gate.open()

        let result = await task.result
        guard case let .failure(error) = result else {
            return XCTFail("a task canceled before the guarded entry must not reach the service")
        }
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(stub.installCallCount, 0)
    }

    func testCancelBeforeOperationTaskStartsNeverCallsService() async throws {
        let stub = ScriptedInstallService(candidates: [candidate("late")])
        let model = makeModel(service: stub)
        model.urlText = "fixture"

        // fetch() creates the outer operation task; its MainActor body cannot run until this
        // test suspends, so the immediate cancel() deterministically lands first.
        model.fetch()
        let fetchTask = try XCTUnwrap(model.operationTask)
        model.cancel()
        XCTAssertEqual(model.state, .idle)

        await TestWait.forTask(fetchTask, failureMessage: "pre-start cancelled fetch did not finish")
        XCTAssertFalse(
            stub.fetchCompleted,
            "cancel before the operation task starts must prevent the service fetch"
        )
        XCTAssertNil(model.source)
    }
}
