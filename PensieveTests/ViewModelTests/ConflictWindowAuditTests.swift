import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ConflictWindowAuditTests: XCTestCase {
    private struct FailureCase {
        let error: Error
        let fragments: [String]
        let advice: String?
    }

    func testLoadAndApplyKeepOriginalGitFailureAndLastCycleStatus() async throws {
        let h = try await SyncFailureAuditFixture()
        defer { try? h.disk.remove() }
        let status = try await h.seedCycle()
        let container = try makeContainer()
        let failures: [FailureCase] = [
            .init(error: h.staleLockFailure(),
                  fragments: ["rebase --abort failed (exit", "index.lock': File exists."], advice: nil),
            .init(error: GitError.authenticationFailed(remote: "https://fixture.test/store.git",
                                                       detail: "fatal: credentials rejected"),
                  fragments: ["Authentication to https://fixture.test/store.git failed:", "fatal: credentials rejected"],
                  advice: "Sync over HTTPS needs an access token. Add one in Settings › Sync, then try again.")
        ]
        for apply in [false, true] {
            for failure in failures {
                let before = try h.log()
                let engine = AuditFailureEngine()
                engine.failure = failure.error
                let model = h.window(engine: engine)
                if apply {
                    // Use the real job to group choices, then inject the engine's apply failure.
                    engine.inspection = conflictInspection()
                    await model.loadAndReport(container: container)
                    model.choose("skill:x", .thisMachine)
                    await model.applyAndReport(container: container)
                } else { await model.loadAndReport(container: container) }
                guard case let .error(message) = model.phase else { return XCTFail("Expected window error") }
                if let advice = failure.advice { XCTAssertEqual(message, advice) }
                for raw in ["rebase --abort", "index.lock", "fatal:", h.disk.root] {
                    XCTAssertFalse(message.contains(raw), message)
                }
                try h.assertWindowLine(after: before, status: status, fragments: failure.fragments)
                let (_, printed) = try await h.command(["log", "--lines", "1"])
                for fragment in failure.fragments { XCTAssertTrue(printed.contains(fragment), printed) }
                if let advice = failure.advice { XCTAssertFalse(printed.contains(advice)) }
            }
        }
    }

    func testFailureResolvingAuthenticationBeforeEngineIsLoggedAndScrubsURL() async throws {
        let h = try await SyncFailureAuditFixture()
        defer { try? h.disk.remove() }
        let status = try await h.seedCycle()
        let before = try h.log()
        let git = try h.disk.broken(.developerToolsMissing)
        let model = h.window(engine: AuditFailureEngine(), git: git)
        await model.loadAndReport(container: try makeContainer())
        let message = try XCTUnwrap(GitUsability.developerToolsMissing.message)
        XCTAssertEqual(model.phase, .error(message))
        try h.assertWindowLine(after: before, status: status, fragments: [message])

        let remoteGit = try h.disk.executable("""
            case "$*" in
              *--version*) printf 'git version fixture\\n'; exit 0 ;;
              *) printf 'fatal: cannot read https://user:privatepassword@fixture.example/store.git\\n' >&2; exit 128 ;;
            esac
            """)
        let beforeRemote = try h.log()
        let remoteModel = h.window(engine: AuditFailureEngine(), git: remoteGit)
        await remoteModel.loadAndReport(container: try makeContainer())
        guard case .error = remoteModel.phase else { return XCTFail("Expected remote-read error") }
        try h.assertWindowLine(after: beforeRemote, status: status, fragments: ["fatal: cannot read https://fixture.example"])
        XCTAssertFalse(try h.log().contains("privatepassword"))
    }

    func testClosedWindowStillLogsHeldLoadFailure() async throws {
        let h = try await SyncFailureAuditFixture()
        defer { try? h.disk.remove() }
        let status = try await h.seedCycle()
        let before = try h.log()
        let container = try makeContainer()
        let block = try GitBlockingFixture()
        defer { block.release(); try? block.cleanup() }
        let failure = AuditFailureEngine()
        failure.failure = h.staleLockFailure()
        let engine = HeldConflictEngine(engine: failure, block: block, holdLoad: true,
                                        windowContext: container.mainContext)
        let steps = SyncStepModel()
        let model = h.window(engine: engine, steps: steps)
        let presentation = UUID()
        model.load(container: container, presentation: presentation)
        await TestWait.until(failureMessage: "Load never entered engine") { block.isBlocked }
        model.dismiss(presentation: presentation)
        block.release()
        await steps.waitUntilIdle()
        XCTAssertEqual(model.phase, .loading)
        try h.assertWindowLine(after: before, status: status, fragments: ["rebase --abort failed (exit", "index.lock"])
    }

    func testAdviceReloadBusyAndSuccessDoNotAppendFailures() async throws {
        let h = try await SyncFailureAuditFixture()
        defer { try? h.disk.remove() }
        _ = try await h.seedCycle()
        let before = try h.log()
        for error in [SyncError.conflictSideUnavailable(path: "x"), .conflictRequiresGitResolution(path: "x"),
                      .protectedGitlinkUnavailable(path: "x"), .conflictFolderMustMove(path: "x"),
                      .localConflictFolderMustMove(path: "x"), .incompatibleConflictPicks(path: "x"),
                      .conflictsChanged, .syncInProgress] {
            let engine = AuditFailureEngine()
            engine.inspection = conflictInspection()
            engine.failure = error
            let model = h.window(engine: engine)
            let container = try makeContainer()
            await model.loadAndReport(container: container)
            model.choose("skill:x", .thisMachine)
            await model.applyAndReport(container: container)
            if error == .syncInProgress {
                XCTAssertEqual(model.phase, .error(error.localizedDescription))
            } else { guard case .ready = model.phase else { return XCTFail("Expected choices") } }
        }
        let success = ConflictResolutionModelTests.StubResolutionEngine()
        success.inspections = [conflictInspection()]
        let model = h.window(engine: success)
        let container = try makeContainer()
        await model.loadAndReport(container: container)
        model.choose("skill:x", .thisMachine)
        await model.applyAndReport(container: container)
        XCTAssertEqual(model.phase, .done)
        XCTAssertEqual(try h.log(), before)
    }

    func testUnwritableAuditAndLockFailureKeepSameWindowMessage() async throws {
        let h = try await SyncFailureAuditFixture()
        defer { try? h.disk.remove() }
        let engine = AuditFailureEngine()
        engine.failure = h.staleLockFailure()
        let working = h.window(engine: engine)
        await working.loadAndReport(container: try makeContainer())
        let lockPath = h.disk.support + "/daemon-audit.lock"
        try h.disk.files.deleteFile(at: lockPath)
        try h.disk.files.createDirectory(at: lockPath)
        let unavailableLock = h.window(engine: engine)
        await unavailableLock.loadAndReport(container: try makeContainer())
        XCTAssertEqual(unavailableLock.phase, working.phase)
        try h.disk.files.deleteDirectory(at: h.disk.support)
        try h.disk.files.writeFile(at: h.disk.support, content: "folder unavailable")
        let unwritable = h.window(engine: engine)
        await unwritable.loadAndReport(container: try makeContainer())
        XCTAssertEqual(unwritable.phase, working.phase)
    }
}

@MainActor
final class ConflictWindowAuditScrubTests: XCTestCase {
    func testScrubPrecedesLengthCutAndSurvivesRotation() async throws {
        let token = "TOKENabcdefghijklmnopqrstuvwxyz0123456789TOKEN"
        let password = "URLsecretABCDEFGHIJKLMNOPQRSTUVWXYZ987654321"
        let h = try await SyncFailureAuditFixture(token: token)
        defer { try? h.disk.remove() }
        let status = try await h.seedCycle()
        // Repeat both secrets throughout the output, so the head and tail cuts cross secret-bearing runs.
        let output = String(repeating: token + " https://user:" + password + "@fixture.test/store.git ", count: 180)
        let engine = AuditFailureEngine()
        engine.failure = GitError.commandFailed(args: ["rebase", "--abort"], exitCode: 128, stderr: output)
        let before = try h.log()
        let model = h.window(engine: engine)
        await model.loadAndReport(container: try makeContainer())
        guard case .error = model.phase else { return XCTFail("Expected window error") }
        try h.assertWindowLine(after: before, status: status, fragments: [" [... cut ...] "])
        let failed = String(((try? h.log()) ?? "").dropFirst(before.count))
        XCTAssertTrue(failed.contains(" failed "))
        assertNoPieces(failed, secrets: [token, password])
        h.rotate()
        XCTAssertTrue(h.disk.files.fileExists(at: h.disk.support + "/daemon.log.1"))
        let rotated = (try? h.log(".1")) ?? ""
        XCTAssertTrue(rotated.contains(failed), "Rotation must retain the window's failed line")
        assertNoPieces(rotated, secrets: [token, password])
        assertNoPieces(try h.disk.files.readFile(at: h.disk.support + "/daemon-status.json"), secrets: [token, password])
    }

    private func assertNoPieces(_ text: String, secrets: [String], file: StaticString = #filePath, line: UInt = #line) {
        for secret in secrets {
            XCTAssertFalse(text.contains(secret), file: file, line: line)
            let chars = Array(secret)
            for index in 0...(chars.count - 8) {
                XCTAssertFalse(text.contains(String(chars[index..<(index + 8)])),
                               "Secret fragment at offset \(index)", file: file, line: line)
            }
        }
    }
}

@MainActor
private func makeContainer() throws -> ModelContainer {
    try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
}

private func conflictInspection() -> ConflictInspection {
    .conflicts(ConflictSet(items: [ConflictItem(path: "skills/x/SKILL.md", kind: .body,
        thisMachine: Data("this".utf8), otherMachine: Data("other".utf8))]))
}
