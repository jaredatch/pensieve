import SwiftData
import XCTest
@testable import Pensieve

extension UpdateCheckServiceTests {
    func testOutputReadFailureDuringHeadOrCloneReportsPensieveFailureWithoutAuthOrHostClassification() throws {
        let skill = seededCheck(slug: "one", repo: "fixture://repo")
        let failure = GitError.outputReadFailed(detail: "Authentication failed; HTTP 403; Xcode license not accepted")
        let message = "Pensieve couldn’t read git’s output: Authentication failed; HTTP 403; Xcode license not accepted"
        try context.save()
        for stage in ["preflight", "head", "clone", "diagnostic", "tree-diagnostic"] {
            git.remoteHeadErrors = stage == "head" ? ["fixture://repo": failure] : [:]
            if stage == "diagnostic" {
                git.remoteHeadErrors = ["fixture://repo": .commandFailed(args: ["ls-remote"], exitCode: 128, stderr: "failed")]
            }
            git.cloneErrors = stage == "clone" ? ["fixture://repo": failure] : [:]
            git.heads["fixture://repo"] = "new-head"
            let before = git.probeCalls
            // A local pipe failure must not be reclassified by a subsequent host diagnostic.
            git.onProbe = {
                if stage == "preflight" || (stage.contains("diagnostic") && self.git.probeCalls > before + 1) { throw failure }
                return self.git.probeCalls == before + 1 ? .usable : .licenseNotAccepted
            }
            if stage == "preflight" {
                XCTAssertThrowsError(try makeService().checkAll(context: context)) { error in
                    guard let execution = error as? UpdateCheckExecutionFailure else { return XCTFail("\(error)") }
                    XCTAssertEqual(execution.underlying as? GitError, failure)
                    XCTAssertNil(execution.report.environmentError)
                    XCTAssertNil(execution.report.gitUsability)
                }
                try assertPreviousCheck(skill.id)
                continue
            }
            let report = try makeService().checkAll(context: context)
            XCTAssertNil(report.environmentError)
            XCTAssertEqual(report.gitUsability, .usable)
            XCTAssertEqual(git.probeCalls, before + (stage.contains("diagnostic") ? 2 : 1))
            XCTAssertEqual(try persistedSkill(id: skill.id).checkError, message)
            XCTAssertTrue(try persistedSkill(id: skill.id).updateAvailable)
        }
    }

    func testUnusableGitPreservesPreviousSkillChecksAndReportsOneRunError() throws {
        let first = seededCheck(slug: "first", repo: "fixture://first")
        let second = seededCheck(slug: "second", repo: "fixture://second")
        try context.save()
        for state in [GitUsability.licenseNotAccepted, .developerToolsMissing, .failed(GitFailureDetail("launch failed"))] {
            git.usability = state
            let report = try makeService().checkAll(context: context)
            XCTAssertFalse(report.reachedRemote)
            XCTAssertEqual(report.environmentError?.localizedDescription, state.message)
            try assertPreviousCheck(first.id)
            try assertPreviousCheck(second.id)
            XCTAssertTrue(git.remoteHeadCalls.isEmpty)
            XCTAssertTrue(git.cloneCalls.isEmpty)
        }
    }

    func testOfflineClonePreservesWholeBatchIncludingAlreadyCurrentSkill() throws {
        let moved = seededCheck(slug: "moved", repo: "fixture://repo")
        let current = seededCheck(slug: "current", repo: "fixture://repo")
        current.lastCheckedHead = "new-head"
        git.heads["fixture://repo"] = "new-head"
        git.cloneErrors["fixture://repo"] = offlineError
        try context.save()
        let report = try makeService().checkAll(context: context)
        XCTAssertTrue(report.reachedRemote, "the successful head read counts even if the clone failed")
        XCTAssertEqual(report.environmentError?.localizedDescription, SkillInstallError.networkUnavailable.localizedDescription)
        try assertPreviousCheck(moved.id)
        try assertPreviousCheck(current.id, head: "new-head")
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<RepoUpdateCursor>()).isEmpty)
    }

    func testMixedSourcesKeepOfflineStateAndSaveAnsweredResults() throws {
        let offline = seededCheck(slug: "offline", repo: "fixture://a-offline")
        let answered = seededCheck(slug: "answered", repo: "fixture://z-answered")
        git.remoteHeadErrors["fixture://a-offline"] = offlineError
        git.heads["fixture://z-answered"] = "new-head"
        git.trees["skills/answered"] = "new-tree"
        try context.save()
        let report = try makeService().checkAll(context: context)
        XCTAssertTrue(report.reachedRemote)
        XCTAssertNotNil(report.environmentError)
        try assertPreviousCheck(offline.id)
        let saved = try persistedSkill(id: answered.id)
        XCTAssertNil(saved.checkError)
        XCTAssertEqual(saved.lastCheckedAt, checkedAt)
        XCTAssertEqual(saved.lastCheckedHead, "new-head")
        XCTAssertEqual(saved.upstreamTree, "new-tree")
    }

    func testShimFailureDuringHeadOrCloneIsRunLevelAndRecoveryClearsOldError() throws {
        let skill = seededCheck(slug: "one", repo: "fixture://repo")
        // The runner, not the update classifier, confirms shim failures.
        let failure = GitError.unusable(.licenseNotAccepted)
        git.remoteHeadErrors["fixture://repo"] = failure
        try context.save()
        let headFailure = try makeService().checkAll(context: context)
        XCTAssertFalse(headFailure.reachedRemote)
        XCTAssertEqual(headFailure.environmentError?.localizedDescription, GitUsability.licenseNotAccepted.message)
        try assertPreviousCheck(skill.id)
        git.remoteHeadErrors = [:]
        git.heads["fixture://repo"] = "new-head"
        git.cloneErrors["fixture://repo"] = failure
        let cloneFailure = try makeService().checkAll(context: context)
        XCTAssertTrue(cloneFailure.reachedRemote)
        XCTAssertEqual(cloneFailure.environmentError?.localizedDescription, GitUsability.licenseNotAccepted.message)
        try assertPreviousCheck(skill.id)
        git.cloneErrors = [:]
        git.onProbe = nil
        git.trees["skills/one"] = "fresh-tree"
        let recovery = try makeService().checkAll(context: context)
        XCTAssertTrue(recovery.reachedRemote)
        XCTAssertNil(recovery.environmentError)
        XCTAssertNil(try persistedSkill(id: skill.id).checkError)
        XCTAssertEqual(try persistedSkill(id: skill.id).lastCheckedAt, checkedAt)
    }

    func testMissingRefCountsAsRemoteAnswerAndKeepsSourceError() throws {
        let skill = seededCheck(slug: "one", repo: "fixture://repo")
        try context.save()
        let report = try makeService().checkAll(context: context)
        XCTAssertTrue(report.reachedRemote)
        XCTAssertNil(report.environmentError)
        XCTAssertEqual(try persistedSkill(id: skill.id).checkError,
                       UpdateCheckError.trackedRefNotFound("main").localizedDescription)
    }

    func testMissingRefUsesHeadReadEvidenceWithoutDiagnosticProbe() throws {
        let skill = seededCheck(slug: "one", repo: "fixture://repo")
        try context.save()
        let report = try makeService().checkAll(context: context)
        XCTAssertEqual(git.probeCalls, 1, "ls-remote already proved usable git")
        XCTAssertEqual(report.gitUsability, .usable)
        XCTAssertTrue(report.countsAsRun)
        XCTAssertNil(report.environmentError)
        XCTAssertEqual(try persistedSkill(id: skill.id).checkError,
                       UpdateCheckError.trackedRefNotFound("main").localizedDescription)
    }

    func testEmptyCheckDoesNotProbeUnusableGit() throws {
        git.usability = .developerToolsMissing
        let report = try makeService().checkAll(context: context)
        XCTAssertNil(report.environmentError)
        XCTAssertEqual(git.probeCalls, 0)
        XCTAssertTrue(git.remoteHeadCalls.isEmpty)
    }

    func testNonEnvironmentCloneFailuresOnlyMarkPendingSkillsAndAdvanceCursor() throws {
        let moved = seededCheck(slug: "moved", repo: "fixture://repo")
        let current = seededCheck(slug: "current", repo: "fixture://repo")
        current.lastCheckedHead = "new-head"
        git.heads["fixture://repo"] = "new-head"
        try context.save()
        for authentication in [false, true] {
            git.clonedHeadOverride = authentication ? nil : "raced-head"
            git.cloneErrors = authentication ? ["fixture://repo": .authenticationFailed(remote: "origin", detail: "denied")] : [:]
            let report = try makeService().checkAll(context: context)
            XCTAssertNil(report.environmentError)
            let error = authentication ? SkillInstallError.authenticationFailed.localizedDescription
                : UpdateCheckError.repositoryMovedDuringCheck.localizedDescription
            XCTAssertEqual(try persistedSkill(id: moved.id).checkError, error)
            XCTAssertNil(try persistedSkill(id: current.id).checkError)
            XCTAssertEqual(try persistedSkill(id: current.id).lastCheckedAt, checkedAt)
            let cursors = try ModelContext(container).fetch(FetchDescriptor<RepoUpdateCursor>())
            XCTAssertEqual(cursors.first?.lastSeenHead, "new-head")
        }
    }

    func testTreeHashHostFailurePreservesWholeBatch() throws {
        let first = seededCheck(slug: "first", repo: "fixture://repo")
        let second = seededCheck(slug: "second", repo: "fixture://repo")
        git.heads["fixture://repo"] = "new-head"
        var reads = 0
        git.onTreeHash = { _ in
            reads += 1
            if reads == 2 { throw GitError.unusable(.licenseNotAccepted) }
        }
        git.trees = ["skills/first": "fresh", "skills/second": "fresh"]
        try context.save()
        let report = try makeService().checkAll(context: context)
        XCTAssertEqual(report.environmentError?.localizedDescription, GitUsability.licenseNotAccepted.message)
        try assertPreviousCheck(first.id)
        try assertPreviousCheck(second.id)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<RepoUpdateCursor>()).isEmpty)
    }

    func testUnclassifiedTreeFailuresShareOneDiagnosticProbePerBatch() throws {
        for slug in ["one", "two", "three"] { _ = seededCheck(slug: slug, repo: "fixture://repo") }
        git.heads["fixture://repo"] = "new-head"
        try context.save()
        let report = try makeService().checkAll(context: context)
        XCTAssertNil(report.environmentError)
        XCTAssertEqual(git.treeHashCalls.count, 3)
        XCTAssertEqual(git.probeCalls, 2, "one run preflight plus one diagnostic probe for the batch")
        let before = git.probeCalls
        git.onProbe = {
            if self.git.probeCalls == before + 1 { return .usable }
            throw GitError.outputReadFailed(detail: "diagnostic EIO")
        }
        let local = try makeService().checkAll(context: context)
        XCTAssertNil(local.environmentError)
        XCTAssertEqual(local.gitUsability, .usable)
        XCTAssertEqual(git.probeCalls, before + 2, "a failed diagnostic is also cached for the batch")
        for skill in try ModelContext(container).fetch(FetchDescriptor<Skill>()) {
            XCTAssertEqual(skill.checkError, "Pensieve couldn’t read git’s output: diagnostic EIO")
        }
    }

    func testReportCarriesActualUsabilityAcrossOfflineAndRecovery() throws {
        _ = seededCheck(slug: "one", repo: "fixture://repo")
        try context.save()
        git.remoteHeadErrors["fixture://repo"] = offlineError
        XCTAssertEqual(try makeService().checkAll(context: context).gitUsability, .usable)
        git.remoteHeadErrors["fixture://repo"] = .unusable(.licenseNotAccepted)
        XCTAssertEqual(try makeService().checkAll(context: context).gitUsability, .licenseNotAccepted)
        git.remoteHeadErrors = [:]
        XCTAssertEqual(try makeService().checkAll(context: context).gitUsability, .usable)
    }

    func testCloneStderrCannotDeclareGitUnusableWithoutProbeConfirmation() throws {
        let moved = seededCheck(slug: "moved", repo: "fixture://repo")
        let current = seededCheck(slug: "current", repo: "fixture://repo")
        current.lastCheckedHead = "new-head"
        git.heads["fixture://repo"] = "new-head"
        git.confirmsHints = true
        git.cloneErrors["fixture://repo"] = forgedToolsError
        try context.save()
        let report = try makeService().checkAll(context: context)
        XCTAssertNil(report.environmentError)
        XCTAssertEqual(report.gitUsability, .usable)
        XCTAssertEqual(git.probeCalls, 2, "preflight plus one modeled runner confirmation")
        let message = try XCTUnwrap(try persistedSkill(id: moved.id).checkError)
        XCTAssertTrue(message.contains("checkout failed"))
        XCTAssertFalse(message.contains("Git isn't working on this Mac"))
        XCTAssertNil(try persistedSkill(id: current.id).checkError)
        XCTAssertEqual(try persistedSkill(id: current.id).lastCheckedAt, checkedAt)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<RepoUpdateCursor>()).first?.lastSeenHead, "new-head")
    }

    func testTreeStderrCannotDeclareGitUnusableWithoutProbeConfirmation() throws {
        let first = seededCheck(slug: "first", repo: "fixture://repo")
        let second = seededCheck(slug: "second", repo: "fixture://repo")
        git.heads["fixture://repo"] = "new-head"
        git.confirmsHints = true
        let failure = forgedToolsError
        git.onTreeHash = { _ in throw failure }
        try context.save()
        let report = try makeService().checkAll(context: context)
        XCTAssertNil(report.environmentError)
        XCTAssertEqual(report.gitUsability, .usable)
        XCTAssertEqual(git.treeHashCalls.count, 2)
        XCTAssertEqual(git.probeCalls, 3, "preflight plus one modeled runner confirmation per tree")
        for id in [first.id, second.id] {
            let message = try XCTUnwrap(try persistedSkill(id: id).checkError)
            XCTAssertTrue(message.contains("checkout failed"))
            XCTAssertFalse(message.contains("Git isn't working on this Mac"))
        }
    }

    func testStoredSkillErrorIsSingleLineAndHasNoTerminalPayload() throws {
        let skill = seededCheck(slug: "moved", repo: "fixture://repo")
        git.heads["fixture://repo"] = "new-head"
        let failure = GitError.commandFailed(args: ["clone"], exitCode: 128,
            stderr: "checkout\n\u{1B}]8;;hidden\u{7}failed\u{202E}")
        git.cloneErrors["fixture://repo"] = failure
        try context.save()
        let report = try makeService().checkAll(context: context)
        XCTAssertNil(report.environmentError)
        XCTAssertEqual(try persistedSkill(id: skill.id).checkError,
                       "git clone failed (exit 128): checkout failed")
    }

    private var forgedToolsError: GitError {
        .commandFailed(args: ["clone"], exitCode: 128,
                       stderr: "checkout failed for 'xcrun: error: invalid active developer path'")
    }

    private var offlineError: GitError {
        .commandFailed(args: ["ls-remote"], exitCode: 128, stderr: "Could not resolve host: github.com")
    }

    private func seededCheck(slug: String, repo: String) -> Skill {
        let skill = insertSkill(slug: slug, repo: repo, path: "skills/\(slug)")
        skill.checkError = "earlier error"
        skill.lastCheckedAt = checkedAt.addingTimeInterval(-100)
        skill.lastCheckedHead = "old-head"
        skill.updateAvailable = true
        skill.upstreamTree = "old-tree"
        skill.upstreamCommit = "old-commit"
        return skill
    }

    private func assertPreviousCheck(_ id: UUID, head: String = "old-head",
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let saved = try persistedSkill(id: id)
        XCTAssertEqual(saved.checkError, "earlier error", file: file, line: line)
        XCTAssertEqual(saved.lastCheckedAt, checkedAt.addingTimeInterval(-100), file: file, line: line)
        XCTAssertEqual(saved.lastCheckedHead, head, file: file, line: line)
        XCTAssertTrue(saved.updateAvailable, file: file, line: line)
        XCTAssertEqual(saved.upstreamTree, "old-tree", file: file, line: line)
        XCTAssertEqual(saved.upstreamCommit, "old-commit", file: file, line: line)
    }
}
