import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class UpdatesViewModelTests: XCTestCase {
    var tempDir: String!
    var fileService: FileService!
    var container: ModelContainer!
    var context: ModelContext!

    override func setUpWithError() throws {
        fileService = FileService()
        tempDir = NSTemporaryDirectory() + "PensieveUpdatesViewModelTests-\(UUID().uuidString)"
        try fileService.createDirectory(at: tempDir)
        container = try ModelContainer(
            for: Skill.self, RepoUpdateCursor.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        if let tempDir, fileService.directoryExists(at: tempDir) {
            try fileService.deleteDirectory(at: tempDir)
        }
    }

    func testNoticeTextUsesSingularCopyForOneUpdate() {
        XCTAssertEqual(UpdatesViewModel.noticeText(count: 1), "1 skill update available")
    }

    func testNoticeTextUsesPluralCopyForFiveUpdates() {
        XCTAssertEqual(UpdatesViewModel.noticeText(count: 5), "5 skill updates available")
    }

    func testRowsDeriveSelectionNoticeAndValidatedCompareLink() async throws {
        let eligible = insertUpdateSkill(slug: "eligible")
        let errored = insertUpdateSkill(slug: "errored")
        errored.checkError = "offline"
        let empty = insertUpdateSkill(slug: "empty")
        empty.installedOrigin = .empty
        let unversioned = Skill(name: "Unversioned", directoryName: "unversioned")
        unversioned.updateAvailable = true
        context.insert(unversioned)
        try context.save()

        XCTAssertTrue(UpdatesViewModel.isEligibleForUpdates(eligible))
        XCTAssertFalse(UpdatesViewModel.isEligibleForUpdates(errored))
        XCTAssertFalse(UpdatesViewModel.isEligibleForUpdates(empty))
        XCTAssertFalse(UpdatesViewModel.isEligibleForUpdates(unversioned))
        XCTAssertEqual(
            UpdatesViewModel.noticeCount(in: [eligible, errored, empty, unversioned]),
            1
        )

        let derived = try UpdatesViewModel.makeRow(skill: eligible, driftedLocally: false)
        let model = makeModel(rows: [derived])
        await model.loadAndReport(context: context)

        XCTAssertEqual(model.rows, [derived])
        XCTAssertEqual(model.selectedSkillIDs, Set([eligible.id]))
        XCTAssertEqual(derived.shortInstalledCommit, "1111111")
        XCTAssertEqual(derived.shortUpstreamCommit, "2222222")
        XCTAssertEqual(derived.repositoryDisplay, "example/repository")
        XCTAssertEqual(derived.repositoryPath, "skills/eligible")
        XCTAssertEqual(
            derived.compareURL?.absoluteString,
            "https://github.com/example/repository/compare/"
                + "1111111111111111111111111111111111111111"
                + "...2222222222222222222222222222222222222222"
        )
        model.selectNone()
        XCTAssertEqual(model.selectedCount, 0)
        model.selectAll()
        XCTAssertEqual(model.selectedCount, 1)
    }

    func testDriftedSkillRequiresConfirm() async throws {
        let skill = insertUpdateSkill(slug: "drifted")
        try context.save()
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: true)
        let calls = LockedCallRecorder()
        let model = makeModel(rows: [row], apply: { id, _, _, _, _, _ in
            calls.append(id)
            return try self.completion(for: skill)
        })
        await model.loadAndReport(context: context)

        await model.applySelectedAndReport(context: context)

        XCTAssertEqual(calls.values, [], "the engine must be unreachable before explicit confirm")
        XCTAssertEqual(model.status(for: row), .confirmationRequired)
        model.setDriftConfirmation(true, for: row)
        await model.applySelectedAndReport(context: context)
        XCTAssertEqual(calls.values, [skill.id])
        XCTAssertEqual(model.status(for: row), .updated)
    }

    func testApplyTimeDriftSurfacesConfirmationAndAllowsRetry() async throws {
        let skill = insertUpdateSkill(slug: "apply-time-drift")
        try context.save()
        let cleanRow = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let overwriteFlags = LockedBoolRecorder()
        let model = makeModel(rows: [cleanRow], apply: { _, _, _, allowOverwrite, _, _ in
            overwriteFlags.append(allowOverwrite)
            guard allowOverwrite else {
                throw SkillUpdateFlowError.localEditsRequireConfirmation
            }
            return try self.completion(for: skill)
        })
        await model.loadAndReport(context: context)

        await model.applySelectedAndReport(context: context)

        let driftedRow = try XCTUnwrap(model.rows.first)
        XCTAssertEqual(model.status(for: driftedRow), .confirmationRequired)
        XCTAssertTrue(driftedRow.driftedLocally)
        model.setDriftConfirmation(true, for: driftedRow)
        await model.applySelectedAndReport(context: context)
        XCTAssertEqual(overwriteFlags.values, [false, true])
        XCTAssertEqual(model.status(for: driftedRow), .updated)
    }

    func testApplyRefusesWhenRemoteMovedOffPin() async throws {
        let fixture = try prepareRealPinnedUpdate()
        XCTAssertEqual(fixture.skill.installedOrigin?.path, "skills/vendor")
        try fileService.writeFile(
            at: fixture.repository + "/README.md",
            content: "move HEAD without changing the skill subtree\n"
        )
        _ = try commit(
            fixture.repository,
            message: "move branch without touching the skill subtree"
        )
        let model = makeRealModel(fixture: fixture)
        await model.loadAndReport(context: context)

        await model.applySelectedAndReport(context: context)

        let row = try XCTUnwrap(model.rows.first)
        guard case let .failed(message, offersRecheck) = model.status(for: row) else {
            return XCTFail("a moved branch must report a per-skill failure")
        }
        XCTAssertEqual(message, SkillUpdateFlowError.repositoryChangedMessage)
        XCTAssertTrue(offersRecheck)
        XCTAssertTrue(fixture.skill.updateAvailable)
        XCTAssertEqual(fixture.skill.upstreamCommit, fixture.pinnedCommit)
        XCTAssertTrue(
            try fileService.readFile(at: fixture.storeRoot + "/skills/vendor/SKILL.md")
                .contains("old body")
        )
    }

    func testPinnedApplyClearsFlagsRefreshesCoordinatesAndFrontmatter() async throws {
        let fixture = try prepareRealPinnedUpdate()
        let model = makeRealModel(fixture: fixture)
        await model.loadAndReport(context: context)
        let row = try XCTUnwrap(model.rows.first)

        model.viewChanges(for: row, context: context)
        await TestWait.until(failureMessage: "update diff did not finish") { model.diffLoadingSkillID == nil }

        let diff = try XCTUnwrap(model.presentedDiff)
        XCTAssertTrue(diff.currentSkillMarkdown.contains("old body"))
        XCTAssertTrue(diff.upstreamSkillMarkdown.contains("fresh body"))
        model.dismissDiff()

        await model.applySelectedAndReport(context: context)

        XCTAssertEqual(model.status(for: row), .updated)
        XCTAssertFalse(fixture.skill.updateAvailable)
        XCTAssertNil(fixture.skill.upstreamTree)
        XCTAssertNil(fixture.skill.upstreamCommit)
        XCTAssertNil(fixture.skill.upstreamCommitDate)
        XCTAssertEqual(fixture.skill.installedOrigin?.installedCommit, fixture.pinnedCommit)
        XCTAssertEqual(fixture.skill.name, "Fresh Name")
        XCTAssertEqual(fixture.skill.skillDescription, "Fresh Description")
        XCTAssertTrue(
            try fileService.readFile(at: fixture.storeRoot + "/skills/vendor/SKILL.md")
                .contains("fresh body")
        )
    }

    func testBatchFailureContinuesToRemainingSkill() async throws {
        let first = insertUpdateSkill(slug: "first")
        let second = insertUpdateSkill(slug: "second")
        try context.save()
        let rows = try [first, second].map {
            try UpdatesViewModel.makeRow(skill: $0, driftedLocally: false)
        }
        let calls = LockedCallRecorder()
        let model = makeModel(rows: rows, apply: { id, _, _, _, _, _ in
            calls.append(id)
            if id == first.id { throw FixtureError.expectedFailure }
            return try self.completion(for: second)
        })
        await model.loadAndReport(context: context)

        await model.applySelectedAndReport(context: context)

        XCTAssertEqual(calls.values, [first.id, second.id])
        guard case .failed = model.status(for: rows[0]) else {
            return XCTFail("the first failure must remain visible")
        }
        XCTAssertEqual(model.status(for: rows[1]), .updated)
    }

    func testViewChangesRefusesMovedPinWithoutMutatingSkill() throws {
        let fixture = try prepareRealPinnedUpdate()
        let before = try fileService.readData(
            at: fixture.storeRoot + "/skills/vendor/SKILL.md"
        )
        try writeSkill(
            name: "Moved Again",
            description: "unreviewed",
            body: "third body",
            repository: fixture.repository
        )
        _ = try commit(fixture.repository, message: "move before diff")

        XCTAssertThrowsError(
            try fixture.service.previewUpdate(PinnedSkillUpdate(skill: fixture.skill))
        ) { error in
            XCTAssertEqual(error as? SkillUpdateFlowError, .repositoryChanged)
            XCTAssertEqual(error.localizedDescription, SkillUpdateFlowError.repositoryChangedMessage)
        }
        XCTAssertEqual(
            try fileService.readData(at: fixture.storeRoot + "/skills/vendor/SKILL.md"),
            before
        )
        XCTAssertTrue(fixture.skill.updateAvailable)
        XCTAssertEqual(fixture.skill.upstreamCommit, fixture.pinnedCommit)
    }
}
