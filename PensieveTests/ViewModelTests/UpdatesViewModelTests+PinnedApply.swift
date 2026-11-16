import SwiftData
import XCTest
@testable import Pensieve

extension UpdatesViewModelTests {
    func testUpdateInstallsThePinnedCommitAfterTheBranchMovesOn() async throws {
        let fixture = try prepareRealPinnedUpdate(includingCompanionFiles: true)
        let pinnedFiles = try snapshotFiles(at: fixture.repository + "/skills/vendor")
        try moveBranchBeyondPin(fixture)
        let model = makeRealModel(fixture: fixture)
        await model.loadAndReport(context: context)
        await model.applySelectedAndReport(context: context)
        try assertPinnedUpdateInstalled(fixture, model: model, files: pinnedFiles)
    }

    func testUpdateRefusesASavedVersionTheBranchNoLongerHolds() async throws {
        let fixture = try prepareRealPinnedUpdate(includingCompanionFiles: true)
        try withdrawPin(fixture)
        let model = makeRealModel(fixture: fixture)
        // Disk facts have moved since this Mac read them; refusal must not ingest them.
        try writeSkill(name: "Changed on disk", description: "Pending refresh", body: "local body",
                       repository: fixture.storeRoot)
        let ingest = StoreIngestState.shared(for: container)
        ingest.invalidate()
        await model.loadAndReport(context: context)
        model.setDriftConfirmation(true, for: try XCTUnwrap(model.rows.first))
        let before = try snapshotSkill(fixture)
        await model.applySelectedAndReport(context: context)
        try assertUpdateFailure(model, message: withdrawnMessage(fixture), offersRecheck: true)
        XCTAssertEqual(try snapshotSkill(fixture), before)
        XCTAssertEqual(try fileService.listDirectory(at: fixture.service.scratchRoot), [])
        XCTAssertTrue(ingest.needsRebuild, "Refusal must leave the pending refresh untouched")
    }

    func testUpdateRefusesWhenTheTrackedBranchIsGone() async throws {
        let fixture = try prepareRealPinnedUpdate(includingCompanionFiles: true)
        let pinnedFiles = try snapshotFiles(at: fixture.repository + "/skills/vendor")
        XCTAssertEqual(try rawGit(["-C", fixture.repository, "checkout", "--detach"]), 0)
        XCTAssertEqual(try rawGit(["-C", fixture.repository, "branch", "-D", "main"]), 0)
        let model = makeRealModel(fixture: fixture)
        await model.loadAndReport(context: context)
        let before = try snapshotSkill(fixture)
        await model.applySelectedAndReport(context: context)
        try assertUpdateFailure(model, message: withdrawnMessage(fixture), offersRecheck: true)
        XCTAssertEqual(try snapshotSkill(fixture), before)
        XCTAssertEqual(try fileService.listDirectory(at: fixture.service.scratchRoot), [])
        // Re-check resolves a same-named tag too, so Update follows it after branch deletion.
        XCTAssertEqual(try rawGit(["-C", fixture.repository, "tag", "main", fixture.pinnedCommit]), 0)
        await model.applySelectedAndReport(context: context)
        try assertPinnedUpdateInstalled(fixture, model: model, files: pinnedFiles)
    }

    func testUpdateInstallsNothingWhenTheBranchCannotBeConfirmed() async throws {
        let fixture = try prepareRealPinnedUpdate(includingCompanionFiles: true)
        try moveBranchBeyondPin(fixture)
        let failures: [(Error, String)] = [
            (GitError.commandFailed(args: [tempDir + "/scratch"], exitCode: 128,
                                    stderr: "remote: server supplied private text"), ""),
            (GitError.commandFailed(args: [], exitCode: 128, stderr: "Could not resolve host: github.com"),
             ". Couldn't reach GitHub — check your internet connection and try again")
        ]
        let git = PinnedPreviewGit()
        let lockPath = tempDir + "/sync.lock"
        let lockAvailable = LockedBoolRecorder()
        git.questionObservation = {
            let lock = SyncLock.tryAcquire(at: lockPath)
            lockAvailable.append(lock != nil)
            lock?.release()
        }
        let service = pinnedPreviewService(fixture, git: git)
        let model = makeRealModel(fixture: fixture, service: service)
        await model.loadAndReport(context: context)
        for (failure, reason) in failures {
            git.questionFailure = failure
            let before = try snapshotSkill(fixture)
            await model.applySelectedAndReport(context: context)
            try assertUpdateFailure(model, message: unconfirmedMessage(fixture) + reason, offersRecheck: false)
            XCTAssertEqual(try snapshotSkill(fixture), before)
            XCTAssertEqual(try fileService.listDirectory(at: fixture.service.scratchRoot), [])
            XCTAssertFalse(lockAvailable.values.isEmpty)
            XCTAssertTrue(lockAvailable.values.allSatisfy { $0 }, "The question must never hold the library lock")
            XCTAssertEqual(try fileService.listDirectory(at: service.scratchRoot), [])
        }
    }

    func testUpdateInstallsASavedVersionOnceItIsMergedBackIntoTheBranch() async throws {
        let fixture = try prepareRealPinnedUpdate(includingCompanionFiles: true)
        let pinnedFiles = try snapshotFiles(at: fixture.repository + "/skills/vendor")
        try withdrawPin(fixture)
        let model = makeRealModel(fixture: fixture)
        await model.loadAndReport(context: context)
        let before = try snapshotSkill(fixture)
        await model.applySelectedAndReport(context: context)
        try assertUpdateFailure(model, message: withdrawnMessage(fixture), offersRecheck: true)
        XCTAssertEqual(try snapshotSkill(fixture), before)
        XCTAssertEqual(try fileService.listDirectory(at: fixture.service.scratchRoot), [])
        // Keep the rewritten files on the first parent; the reviewed commit is the second parent.
        XCTAssertEqual(try rawGit(["-C", fixture.repository, "-c", "user.name=t", "-c", "user.email=t@t",
                                   "merge", "--no-ff", "-s", "ours", fixture.pinnedCommit, "-m", "restore history"]), 0)
        await model.applySelectedAndReport(context: context)
        try assertPinnedUpdateInstalled(fixture, model: model, files: pinnedFiles)
    }

    func testUpdateCannotConfirmFromAHistoryCutShort() async throws {
        let fixture = try prepareRealPinnedUpdate(includingCompanionFiles: true)
        try moveBranchBeyondPin(fixture)
        let shallow = tempDir + "/shallow"
        XCTAssertEqual(try rawGit(["clone", "--depth", "1", "--", "file://" + fixture.repository, shallow]), 0)
        var origin = try XCTUnwrap(fixture.skill.installedOrigin)
        origin.repo = "file://" + shallow
        fixture.skill.installedOrigin = origin
        try context.save()
        let model = makeRealModel(fixture: fixture)
        await model.loadAndReport(context: context)
        let before = try snapshotSkill(fixture)
        await model.applySelectedAndReport(context: context)
        try assertUpdateFailure(model, message: unconfirmedMessage(fixture), offersRecheck: false)
        XCTAssertEqual(try snapshotSkill(fixture), before)
        XCTAssertEqual(try fileService.listDirectory(at: fixture.service.scratchRoot), [])
    }

    private func withdrawPin(_ fixture: RealFixture) throws {
        let installed = try XCTUnwrap(fixture.skill.installedOrigin?.installedCommit)
        XCTAssertEqual(try rawGit(["-C", fixture.repository, "reset", "--hard", installed]), 0)
        try moveBranchBeyondPin(fixture)
        XCTAssertEqual(try rawGit(["-C", fixture.repository, "merge-base", "--is-ancestor",
                                   fixture.pinnedCommit, "HEAD"]), 1)
    }

    private func withdrawnMessage(_ fixture: RealFixture) -> String {
        "Commit \(fixture.pinnedCommit.prefix(7)) is no longer on main — re-check to review the latest version"
    }

    private func unconfirmedMessage(_ fixture: RealFixture) -> String {
        "Couldn't confirm commit \(fixture.pinnedCommit.prefix(7)) is still on main, so nothing was installed"
    }

    func testUpdateNamesAPinnedCommitThatIsGoneAndLeavesTheSkillAlone() async throws {
        let fixture = try prepareRealPinnedUpdate(includingCompanionFiles: true)
        fixture.skill.upstreamCommit = String(repeating: "a", count: 40)
        try context.save()
        let model = makeRealModel(fixture: fixture)
        await model.loadAndReport(context: context)
        let before = try snapshotSkill(fixture)
        await model.applySelectedAndReport(context: context)
        try assertUpdateFailure(model,
            message: "Commit aaaaaaa is no longer on main — re-check to review the latest version",
            offersRecheck: true)
        XCTAssertEqual(try snapshotSkill(fixture), before)
        XCTAssertEqual(try fileService.listDirectory(at: fixture.service.scratchRoot), [])
    }

    func testUpdateRefusesAMalformedPinBeforeGitRuns() async throws {
        let fixture = try prepareRealPinnedUpdate(includingCompanionFiles: true)
        for pin in ["main", "--upload-pack=x", "+refs/heads/a:refs/heads/b", "abcdef0",
                    String(repeating: "A", count: 40), String(repeating: "a", count: 40) + "\n"] {
            fixture.skill.upstreamCommit = pin
            try context.save()
            let git = PinnedPreviewGit()
            let service = pinnedPreviewService(fixture, git: git)
            let model = makeRealModel(fixture: fixture, service: service)
            await model.loadAndReport(context: context)
            let before = try snapshotSkill(fixture)
            await model.applySelectedAndReport(context: context)
            try assertUpdateFailure(model,
                message: "This update is no longer pinned — re-check to review the latest version",
                offersRecheck: true)
            if case let .failed(message, _) = model.status(for: try XCTUnwrap(model.rows.first)) {
                XCTAssertFalse(message.contains(pin))
            }
            XCTAssertEqual(git.calls, 0, "Malformed saved pins must never reach git")
            XCTAssertEqual(try snapshotSkill(fixture), before)
            XCTAssertEqual(try fileService.listDirectory(at: fixture.service.scratchRoot), [])
        }
    }

    func testUpdateRefusesAMismatchedDownloadThenInstallsAnHonestOne() async throws {
        let fixture = try prepareRealPinnedUpdate(includingCompanionFiles: true)
        let pinnedFiles = try snapshotFiles(at: fixture.repository + "/skills/vendor")
        try moveBranchBeyondPin(fixture)
        let git = PinnedPreviewGit(wrongHead: true)
        let model = makeRealModel(fixture: fixture, service: pinnedPreviewService(fixture, git: git))
        await model.loadAndReport(context: context)
        for wrongHead in [true, false] {
            git.wrongHead = wrongHead
            git.wrongTree = !wrongHead
            let before = try snapshotSkill(fixture)
            await model.applySelectedAndReport(context: context)
            try assertUpdateFailure(model, message: SkillUpdateFlowError.repositoryChangedMessage,
                                    offersRecheck: true)
            XCTAssertEqual(try snapshotSkill(fixture), before)
            XCTAssertEqual(try fileService.listDirectory(at: fixture.service.scratchRoot), [])
        }
        git.wrongHead = false
        git.wrongTree = false
        await model.applySelectedAndReport(context: context)
        try assertPinnedUpdateInstalled(fixture, model: model, files: pinnedFiles)
    }

    func testUpdateKeepsEachDownloadFailuresOwnMessage() async throws {
        let fixture = try prepareRealPinnedUpdate(includingCompanionFiles: true)
        try moveBranchBeyondPin(fixture)
        let credentials = InMemoryCredentialStore()
        try credentials.store(token: "install-fixture", username: "installer", forHost: CredentialHost.githubInstall)
        try credentials.store(token: "sync-decoy", username: "sync", forHost: "github.com")
        let failures: [(Error, String)] = [
            (GitError.authenticationFailed(remote: "remote: untrusted", detail: "refused"),
             SkillInstallError.authenticationFailed.localizedDescription),
            (GitError.commandFailed(args: [], exitCode: 128, stderr: "Could not resolve host: remote: untrusted"),
             SkillInstallError.networkUnavailable.localizedDescription),
            (GitError.commandFailed(args: [], exitCode: 128, stderr: "remote: Repository not found."),
             SkillInstallError.repositoryNotFound.localizedDescription)
        ]
        for (failure, message) in failures {
            let git = PinnedPreviewGit(failure: failure)
            let service = pinnedPreviewService(fixture, git: git, credentials: credentials)
            let model = makeRealModel(fixture: fixture, service: service)
            await model.loadAndReport(context: context)
            let before = try snapshotSkill(fixture)
            await model.applySelectedAndReport(context: context)
            try assertUpdateFailure(model, message: message, offersRecheck: false)
            XCTAssertEqual(try snapshotSkill(fixture), before)
            XCTAssertEqual(try fileService.listDirectory(at: fixture.service.scratchRoot), [])
            XCTAssertEqual(git.questionCredentials, Array(repeating:
                .httpsToken(username: "installer", token: "install-fixture", host: "github.com"), count: 2))
            XCTAssertEqual(git.downloadCredentials, [
                .httpsToken(username: "installer", token: "install-fixture", host: "github.com")
            ])
        }
    }

    private func moveBranchBeyondPin(_ fixture: RealFixture) throws {
        try writeSkill(name: "Moved Again", description: "unreviewed", body: "third body",
                       repository: fixture.repository)
        try writeCompanionFiles(body: "third body", repository: fixture.repository)
        _ = try commit(fixture.repository, message: "unreviewed change")
    }

    private func assertUpdateFailure(_ model: UpdatesViewModel, message: String,
                                     offersRecheck: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let row = try XCTUnwrap(model.rows.first, file: file, line: line)
        XCTAssertEqual(model.status(for: row), .failed(message: message, offersRecheck: offersRecheck),
                       file: file, line: line)
    }

    private func assertPinnedUpdateInstalled(_ fixture: RealFixture, model: UpdatesViewModel,
                                             files: [String: ApplyFileSnapshot],
                                             file: StaticString = #filePath, line: UInt = #line) throws {
        let row = try XCTUnwrap(model.rows.first, file: file, line: line)
        XCTAssertEqual(model.status(for: row), .updated, file: file, line: line)
        XCTAssertEqual(try fileService.listDirectory(at: fixture.service.scratchRoot), [], file: file, line: line)
        XCTAssertEqual(try snapshotFiles(at: fixture.storeRoot + "/skills/vendor"), files, file: file, line: line)
        let saved = try snapshotSkill(fixture).record
        XCTAssertEqual(saved.installedOrigin?.installedCommit, fixture.pinnedCommit, file: file, line: line)
        XCTAssertEqual(saved.installedOrigin?.installedTree, row.upstreamTree, file: file, line: line)
        XCTAssertFalse(saved.updateAvailable, file: file, line: line)
        let manifest = try ManifestService(fileService: fileService).read(fromRoot: fixture.storeRoot)
        let overlay = try XCTUnwrap(manifest.skills.first { $0.slug == "vendor" }, file: file, line: line)
        guard case let .installed(origin) = overlay.origin else {
            return XCTFail("Updated overlay must retain the pinned origin", file: file, line: line)
        }
        XCTAssertEqual(origin.installedCommit, fixture.pinnedCommit, file: file, line: line)
        XCTAssertEqual(origin.installedTree, row.upstreamTree, file: file, line: line)
    }
}
