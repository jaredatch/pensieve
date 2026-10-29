import Darwin
import XCTest
@testable import Pensieve

extension ConflictFolderResolutionTests {
    func assertUnreadableOrigHeadReportsRefusal(_ occupant: String) async throws {
        let fixture = try makeFixture(link: false)
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        let folder = fixture.storeB + "/" + fixture.path
        let origHead = fixture.storeB + "/.git/rebase-merge/orig-head"
        let engine = try fixture.folderObservationEngine(change: "printf extra > '\(folder)/extra'",
            afterAbortFailure: fixture.origHeadReplacementCommand(occupant))
        let model = ConflictResolutionModel(engine: engine, git: fixture.git,
            credentials: InMemoryCredentialStore(), root: fixture.storeB, steps: SyncStepModel())
        await model.loadAndReport(container: fixture.contextB.container)
        guard case let .ready(groups) = model.phase else { return XCTFail("Conflict must load for \(occupant)") }
        for group in groups { model.choose(group.id, .thisMachine) }
        try fixture.files.writeFile(at: fixture.root + "/folder-armed", content: occupant)
        await model.applyAndReport(container: fixture.contextB.container)
        if occupant == "FIFO", model.isApplying {
            // Unblock an unbounded reader after its wait fails, then join resolution before teardown.
            let writer = Darwin.open(origHead, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { Darwin.close(writer) }
            await TestWait.until(failureMessage: "FIFO reader did not finish after release") { !model.isApplying }
        }
        let original = try NativeTestWork.run {
            try fixture.git.runOrThrow(["-C", fixture.storeB, "rev-parse", "ORIG_HEAD"], in: nil)
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try assertOrigHeadInstallation(occupant, fixture: fixture, original: original)
        let trace = try fixture.files.readFile(at: fixture.root + "/abort-results")
        XCTAssertEqual(trace, "128\n", "\(occupant): native abort must run exactly once")
        if case let .error(message) = model.phase {
            XCTAssertTrue(message.contains("can’t replace the folder"), message)
            assertMoveFolderMessage(message, path: fixture.path)
            XCTAssertTrue(message.contains("couldn’t return the store to rest"), message)
            XCTAssertTrue(message.contains("would lose untracked files"), message)
        } else {
            XCTFail("\(occupant): expected refused abort, got \(model.phase); "
                + "selection error: \(model.selectionError ?? "none"); abort trace: \(trace.debugDescription)")
        }
        let expected: FileEntryType? = occupant == "link" ? .symlink
            : occupant == "oversized" ? .regular : occupant == "FIFO" ? .other : nil
        XCTAssertEqual(try fixture.files.entryTypeWithoutFollowingLinks(at: origHead), expected,
                       "\(occupant): abort must preserve the metadata occupant")
        XCTAssertEqual(try fixture.files.entryTypeWithoutFollowingLinks(at: folder), .directory, occupant)
        XCTAssertEqual(try fixture.files.readFile(at: folder + "/extra"), "extra", occupant)
    }

    private func assertOrigHeadInstallation(_ occupant: String, fixture: SyncConflictByteFixture,
                                           original: String) throws {
        let evidence = try XCTUnwrap(JSONSerialization.jsonObject(with:
            fixture.files.readData(at: fixture.root + "/orig-head-evidence.json")) as? [String: Any])
        let saved = try fixture.files.readFile(at: fixture.root + "/saved-orig-head")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(GitObjectID.parse(saved, casePolicy: .lowercase), original, occupant)
        switch occupant {
        case "link":
            XCTAssertEqual(evidence["mode"] as? Int, Int(S_IFLNK))
            XCTAssertEqual(evidence["target"] as? String, fixture.root + "/saved-orig-head")
        case "oversized":
            XCTAssertEqual(evidence["mode"] as? Int, Int(S_IFREG))
            XCTAssertGreaterThan(try XCTUnwrap(evidence["size"] as? Int), 64 * 1_024)
            XCTAssertEqual(evidence["trimmed"] as? String, original)
        case "FIFO":
            XCTAssertEqual(evidence["mode"] as? Int, Int(S_IFIFO), "lstat must prove this is a FIFO")
        default:
            XCTAssertEqual(evidence["missing"] as? Bool, true)
        }
    }

    func assertLaterAbortPreservesFolder(_ fixture: SyncConflictByteFixture,
                                         model: ConflictResolutionModel) async throws {
        let folder = fixture.storeB + "/" + fixture.path
        try fixture.files.writeFile(at: folder + "/later", content: "written after resolve")
        do {
            _ = try NativeTestWork.run(container: fixture.contextB.container) { context in
                try fixture.engine.sync(root: fixture.storeB, message: "retry interrupted sync",
                                        credential: nil, context: context)
            }
            XCTFail("Later sync must report the blocking folder without deleting it")
        } catch {
            assertMoveFolderMessage(error.localizedDescription, path: fixture.path)
        }
        XCTAssertEqual(try fixture.files.readFile(at: folder + "/extra"), "extra")
        XCTAssertEqual(try fixture.files.readFile(at: folder + "/later"), "written after resolve")
        await model.loadAndReport(container: fixture.contextB.container)
        guard case let .error(message) = model.phase else { return XCTFail("Inspection must also preserve the folder") }
        assertMoveFolderMessage(message, path: fixture.path)
        XCTAssertEqual(try fixture.files.readFile(at: folder + "/later"), "written after resolve")
        XCTAssertTrue(fixture.git.isRebaseInProgress(at: fixture.storeB))
        try fixture.files.publishDirectory(at: folder, to: fixture.root + "/saved-folder")
        let outcome = try NativeTestWork.run(container: fixture.contextB.container) { context in
            try fixture.engine.sync(root: fixture.storeB, message: "retry after moving folder",
                                    credential: nil, context: context)
        }
        XCTAssertEqual(outcome, .conflicted(fixture.expectedPaths))
        XCTAssertEqual(try fixture.files.readFile(at: fixture.root + "/saved-folder/later"), "written after resolve")
        try assertChosen(fixture, link: false, stores: [fixture.storeB])
    }

    func assertInspectionAbortRefusal() async throws {
        let fixture = try makeFixture(link: false)
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        let folder = fixture.storeB + "/" + fixture.path
        let engine = try fixture.folderObservationEngine(change: "printf extra > '\(folder)/extra'")
        let model = ConflictResolutionModel(engine: engine, git: fixture.git,
            credentials: InMemoryCredentialStore(), root: fixture.storeB, steps: SyncStepModel())
        try fixture.files.writeFile(at: fixture.root + "/folder-armed", content: "inspect obstruction")
        await model.loadAndReport(container: fixture.contextB.container)
        guard case let .error(message) = model.phase else { return XCTFail("Inspect must report its failed abort") }
        assertMoveFolderMessage(message, path: fixture.path)
        XCTAssertTrue(message.contains("couldn’t return the store to rest"), message)
        XCTAssertEqual(message.components(separatedBy: "would lose untracked files").count - 1, 1,
                       "Do not repeat the native refusal in the error")
        XCTAssertEqual(try fixture.files.readFile(at: fixture.root + "/abort-results"), "128\n",
                       "Inspection must attempt its failed abort only once")
        XCTAssertEqual(try fixture.files.readFile(at: folder + "/extra"), "extra")
    }

    func assertAbortProofFailure() async throws {
        let fixture = try makeFixture(link: false)
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        let folder = fixture.storeB + "/" + fixture.path
        let engine = try fixture.folderObservationEngine(change: "printf extra > '\(folder)/extra'",
            afterAbortFailure: "rm -f '\(fixture.storeB)/.git/rebase-merge/orig-head'")
        let model = ConflictResolutionModel(engine: engine, git: fixture.git,
            credentials: InMemoryCredentialStore(), root: fixture.storeB, steps: SyncStepModel())
        await model.loadAndReport(container: fixture.contextB.container)
        guard case let .ready(groups) = model.phase else { return XCTFail("Conflict must load") }
        for group in groups { model.choose(group.id, .thisMachine) }
        try fixture.files.writeFile(at: fixture.root + "/folder-armed", content: "proof disappears after native refusal")
        await model.applyAndReport(container: fixture.contextB.container)
        guard case let .error(message) = model.phase else { return XCTFail("Report the refused abort") }
        XCTAssertTrue(message.contains("can’t replace the folder"), message)
        assertMoveFolderMessage(message, path: fixture.path)
        XCTAssertTrue(message.contains("couldn’t return the store to rest"), message)
        XCTAssertTrue(message.contains("would lose untracked files"), "Keep Git’s refusal when the proof fails: " + message)
        XCTAssertEqual(try fixture.files.readFile(at: folder + "/extra"), "extra")
        XCTAssertEqual(try fixture.files.readFile(at: fixture.root + "/abort-results"), "128\n")
    }

    private func assertMoveFolderMessage(_ message: String, path: String) {
        XCTAssertTrue(message.contains(path), message)
        XCTAssertTrue(message.contains("out of the store"), message)
        XCTAssertTrue(message.contains("sync again"), message)
    }
}
