import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class SyncLogPointerTests: XCTestCase {
    func testAbortFailurePointsToLogInCycleAndWindowWithoutExposingGit() async throws {
        let h = try await SyncFailureAuditFixture()
        defer { try? h.disk.remove() }
        let refusal = "fatal: Unable to create '\(h.disk.root)/.git/index.lock': File exists."
        let abort = GitError.commandFailed(args: ["-C", h.disk.root, "rebase", "--abort"],
                                           exitCode: 128, stderr: refusal)
        guard case let .failed(message) = await h.run(abort) else { return XCTFail("Expected failed cycle") }
        assertPointer(message, root: h.disk.root)
        let log = try h.log()
        XCTAssertTrue(log.contains("rebase --abort failed (exit 128)"))
        XCTAssertTrue(log.contains(refusal))

        let git = SyncConflictResolutionTests.StubGit(conflictPath: "skills/x/SKILL.md",
            pullError: GitError.commandFailed(args: ["rebase"], exitCode: 1, stderr: "fatal: pull refused"),
            abortError: abort)
        let engine = SyncEngine(gitService: git, fileService: h.disk.files, lockPath: h.disk.base + "/sync.lock")
        let model = ConflictResolutionModel(engine: engine, git: git, credentials: h.credentials,
                                            root: h.disk.root, steps: SyncStepModel())
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        await model.loadAndReport(container: container)
        guard case let .error(windowMessage) = model.phase else { return XCTFail("Expected window failure") }
        XCTAssertTrue(windowMessage.contains("return the store to rest"))
        assertPointer(windowMessage, root: h.disk.root)

        let blocked = ConflictAbortBlocked(paths: ["skills/x"], underlying: abort)
        guard case let .failed(folderMessage) = await h.run(blocked) else { return XCTFail("Expected folder failure") }
        XCTAssertEqual(folderMessage, "Pensieve couldn’t undo an interrupted sync in the store. "
            + "Move the folder at skills/x out of the store, then sync again.")
        XCTAssertFalse(folderMessage.contains("pensieve log"))
    }

    private func assertPointer(_ message: String, root: String, file: StaticString = #filePath, line: UInt = #line) {
        let sentences = message.split(separator: ".").map(String.init)
        XCTAssertTrue(sentences.last?.contains("pensieve log") == true, message, file: file, line: line)
        XCTAssertTrue(message.hasSuffix("."), message, file: file, line: line)
        for fragment in ["fatal:", "index.lock", "File exists", "rebase", "git ", root, "pull refused"] {
            XCTAssertFalse(message.contains(fragment), message, file: file, line: line)
        }
    }
}
