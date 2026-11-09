import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class SyncFailureCauseTests: XCTestCase {
    private let refusal = "error: Updating the following directories would lose untracked files in them:\n\tskills/x"
    private let pullDetail = "boom\nfatal: more"

    func testRejectedPushShowsCauseAndKeepsAuditDetail() async throws {
        try await assertCycle(args: ["push", "-u", "origin", "main"],
            stderr: "To https://fixture.test/store.git\n ! [rejected] main -> main (fetch first)"
                + "\nerror: failed to push some refs",
            advice: ["push", "Sync again"],
            audit: ["push -u origin main failed (exit 1):", "[rejected]", "failed to push some refs"])
    }

    func testNetworkFailureShowsConnectionAdviceAndKeepsAuditDetail() async throws {
        try await assertCycle(args: ["fetch", "origin", "main"],
            stderr: "fatal: Could not resolve host: fixture.test\nmore network detail",
            advice: ["connection"], audit: ["Could not resolve host"])
    }

    func testMissingStoreOffersSyncSettingsAndKeepsAuditDetail() async throws {
        try await assertCycle(args: ["fetch", "origin", "main"],
            stderr: "remote: Repository not found.\nfatal: missing remote",
            advice: ["Settings › Sync"], audit: ["Repository not found"])
    }

    func testStagingRecordsThisMacsChangesAndKeepsAuditDetail() async throws {
        try await assertCycle(args: ["--literal-pathspecs", "add", "--update"],
            stderr: "error: unable to index file\nfatal: updating files failed",
            advice: ["this Mac’s changes", "Sync again"], audit: ["--literal-pathspecs add --update failed (exit"])
    }

    func testRefusedAbortShowsFolderAdviceAndKeepsAuditDetail() async throws {
        let h = try await SyncFailureAuditFixture()
        defer { try? h.disk.remove() }
        _ = try await assertCycle(h, error: blockedAbort(root: h.disk.root), stderr: refusal,
            advice: [folderAdvice], audit: ["rebase --abort failed (exit 1)", "Updating the following directories"])
    }

    func testFailedReturnToRestShowsSameCauseInCycleAndWindowAndKeepsBothAuditDetails() async throws {
        let h = try await SyncFailureAuditFixture()
        defer { try? h.disk.remove() }
        let failure = try inspectionFailure(h)
        let message = try await assertCycle(h, error: failure, stderr: pullDetail + "\n" + refusal,
            advice: ["return the store to rest", folderAdvice],
            audit: ["rebase failed (exit 1)", "boom", "rebase --abort failed (exit 1)", "Updating the following directories"])
        let git = conflictGit(root: h.disk.root)
        let model = window(h, git: git)
        await model.loadAndReport(container: try context().container)
        XCTAssertEqual(model.phase, .error(message))
    }

    func testUnfinishedInspectionShowsCauseOfFailedReturnToRest() async throws {
        let h = try await SyncFailureAuditFixture()
        defer { try? h.disk.remove() }
        let stderr = "fatal: No rebase in progress?\nmore"
        let git = SyncConflictResolutionTests.StubGit(conflictPath: "skills/x/SKILL.md",
            abortError: GitError.commandFailed(args: ["-C", h.disk.root, "rebase", "--abort"],
                                               exitCode: 128, stderr: stderr))
        let model = window(h, git: git)
        await model.loadAndReport(container: try context().container)
        let message = try windowMessage(model)
        assertClean(message, root: h.disk.root, stderr: stderr)
        assertAdvice(message, ["finish inspecting conflicts", "return the store to rest"])
    }

    func testApplyingChoicesShowsFolderAdviceForBothFailureKinds() async throws {
        let h = try await SyncFailureAuditFixture()
        defer { try? h.disk.remove() }
        let failures: [Error] = [try inspectionFailure(h), blockedAbort(root: h.disk.root)]
        for failure in failures {
            let engine = ConflictResolutionModelTests.StubResolutionEngine()
            engine.inspections = [.conflicts(ConflictSet(items: [
                ConflictItem(path: "skills/x/SKILL.md", kind: .body,
                             thisMachine: Data("this".utf8), otherMachine: Data("other".utf8))
            ]))]
            let model = ConflictResolutionModel(engine: engine,
                git: SyncConflictResolutionTests.StubGit(conflictPath: "skills/x/SKILL.md"),
                credentials: InMemoryCredentialStore(), root: h.disk.root, steps: SyncStepModel())
            let container = try context().container
            await model.loadAndReport(container: container)
            model.choose("skill:x", .thisMachine)
            engine.resolveError = failure
            await model.applyAndReport(container: container)
            let message = try windowMessage(model)
            assertClean(message, root: h.disk.root, stderr: pullDetail + "\n" + refusal)
            assertAdvice(message, [folderAdvice])
        }
    }

    func testInspectionShowsCauseAfterAbortingFailedPull() async throws {
        let h = try await SyncFailureAuditFixture()
        defer { try? h.disk.remove() }
        let git = SyncConflictResolutionTests.StubGit(conflictPath: "skills/x/SKILL.md",
            pullError: GitError.commandFailed(args: ["rebase"], exitCode: 1, stderr: pullDetail))
        let model = window(h, git: git)
        await model.loadAndReport(container: try context().container)
        let message = try windowMessage(model)
        assertClean(message, root: h.disk.root, stderr: pullDetail)
        assertAdvice(message, ["Sync again"])
        XCTAssertEqual(git.abortsAfterPull, 1)
    }

    func testConfigurationFailureShowsSameCauseInSidebarAndSettings() async throws {
        let h = try await SyncFailureAuditFixture()
        defer { try? h.disk.remove() }
        let model = SyncModel(git: h.disk.paths.makeGitService(), root: h.disk.root)
        let stderr = "fatal: not a git repository\nmore"
        model.applyConfiguration(.failure(GitError.commandFailed(
            args: ["-C", h.disk.root, "for-each-ref", "--format=%(refname)", "refs/heads"],
            exitCode: 128, stderr: stderr)), order: model.beginConfiguration())
        let message = try XCTUnwrap(model.configurationError)
        assertClean(message, root: h.disk.root, stderr: stderr)
        assertAdvice(message, ["Sync again"])
        XCTAssertEqual(model.state, .error(message))
    }

    private var folderAdvice: String { "Move the folder at skills/x out of the store, then sync again." }

    private func blockedAbort(root: String) -> ConflictAbortBlocked {
        ConflictAbortBlocked(paths: ["skills/x"], underlying: GitError.commandFailed(
            args: ["-C", root, "rebase", "--abort"], exitCode: 1, stderr: refusal))
    }

    private func conflictGit(root: String) -> SyncConflictResolutionTests.StubGit {
        SyncConflictResolutionTests.StubGit(conflictPath: "skills/x/SKILL.md",
            pullError: GitError.commandFailed(args: ["-C", root, "rebase"], exitCode: 1, stderr: pullDetail),
            abortError: blockedAbort(root: root))
    }

    private func context() throws -> ModelContext {
        ModelContext(try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private func engine(_ h: SyncFailureAuditFixture, git: SyncConflictResolutionTests.StubGit) -> SyncEngine {
        SyncEngine(gitService: git, manifestService: ManifestService(), storeRebuildService: StoreRebuildService(),
                   fileService: h.disk.files, lockPath: h.disk.base + "/sync.lock")
    }

    private func inspectionFailure(_ h: SyncFailureAuditFixture) throws -> Error {
        let engine = engine(h, git: conflictGit(root: h.disk.root))
        do {
            _ = try NativeTestWork.run(container: try context().container) { context in
                try engine.inspectConflicts(root: h.disk.root, credential: nil, context: context)
            }
            XCTFail("Inspection must report the failure to abort")
            return SyncError.ingestIncomplete
        } catch {
            guard case SyncError.returnToRestFailed = error else {
                XCTFail("Expected the production composite, got \(error)")
                return error
            }
            return error
        }
    }

    private func window(_ h: SyncFailureAuditFixture, git: SyncConflictResolutionTests.StubGit)
        -> ConflictResolutionModel {
        ConflictResolutionModel(engine: engine(h, git: git), git: git, credentials: InMemoryCredentialStore(),
                                root: h.disk.root, steps: SyncStepModel())
    }

    private func windowMessage(_ model: ConflictResolutionModel) throws -> String {
        guard case let .error(message) = model.phase else {
            XCTFail("Expected an error in the conflict window, got \(model.phase)")
            return try XCTUnwrap(nil as String?)
        }
        return message
    }

    private func assertCycle(args: [String], stderr: String, advice: [String], audit: [String]) async throws {
        let h = try await SyncFailureAuditFixture()
        defer { try? h.disk.remove() }
        let error = GitError.commandFailed(args: ["-C", h.disk.root] + args, exitCode: 1, stderr: stderr)
        _ = try await assertCycle(h, error: error, stderr: stderr, advice: advice,
                                 audit: ["git -C \(h.disk.root) "] + audit)
    }

    private func assertCycle(_ h: SyncFailureAuditFixture, error: Error, stderr: String,
                             advice: [String], audit: [String]) async throws -> String {
        let result = await h.run(error)
        guard case let .failed(message) = result else {
            XCTFail("Expected a failed cycle, got \(result)")
            return ""
        }
        assertClean(message, root: h.disk.root, stderr: stderr)
        assertAdvice(message, advice)
        let model = SyncModel(git: h.disk.paths.makeGitService(), root: h.disk.root)
        model.apply(result)
        XCTAssertEqual(model.state, .error(message))
        let status = try h.status()
        for fragment in audit { XCTAssertTrue(status.detail.contains(fragment), status.detail) }
        XCTAssertTrue(try h.log().hasSuffix("\(status.timestamp) failed \(status.detail)\n"))
        return message
    }

    private func assertClean(_ message: String, root: String, stderr: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(message.isEmpty, file: file, line: line)
        XCTAssertTrue(message.hasSuffix("."), message, file: file, line: line)
        for fragment in ["\n", "failed (exit", "git ", root] + stderr.components(separatedBy: "\n") {
            XCTAssertFalse(message.contains(fragment), "Unexpected \(fragment.debugDescription) in \(message)",
                           file: file, line: line)
        }
    }

    private func assertAdvice(_ message: String, _ fragments: [String],
                              file: StaticString = #filePath, line: UInt = #line) {
        for fragment in fragments { XCTAssertTrue(message.contains(fragment), message, file: file, line: line) }
    }
}
