import XCTest
@testable import Pensieve

extension ConflictFolderResolutionTests {
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
