import XCTest
@testable import Pensieve

extension ConflictFolderResolutionTests {
    func assertRootTildeConflict() async throws {
        let fixture = try NativeTestWork.run {
            try SyncConflictByteFixture(name: "~notes", initial: .file(Data("base".utf8)),
                this: .file(Data("local".utf8)), other: .folder, rootPath: true)
        }
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        let model = try await choose(fixture, side: .thisMachine)
        XCTAssertEqual(model.phase, .done, "A literal leading tilde must not break conflict loading")
        XCTAssertEqual(try fixture.files.readFile(at: fixture.storeB + "/~notes"), "local")
    }

    func assertIncompatiblePicks() async throws {
        for parentSide in [ConflictSide.thisMachine, .otherMachine] {
            try await assertIncompatiblePicks(parentSide: parentSide)
        }
    }

    private func assertIncompatiblePicks(parentSide: ConflictSide) async throws {
        let fixture = try NativeTestWork.run {
            try SyncConflictByteFixture(name: "separate", initial: .file(Data("base".utf8)),
                this: .file(Data("local".utf8)), other: .folderWith([
                    "SKILL.md": .file(Data("---\nname: Separate\ndescription: Test\n---\nbody\n".utf8))
                ]), skillRoot: true)
        }
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        let model = ConflictResolutionModel(engine: fixture.engine, git: fixture.git,
            credentials: InMemoryCredentialStore(), root: fixture.storeB, steps: SyncStepModel())
        await model.loadAndReport(container: fixture.contextB.container)
        guard case let .ready(groups) = model.phase else { return XCTFail("Conflict must load") }
        XCTAssertGreaterThan(groups.count, 1, "The parent and child must be independently selectable")
        for group in groups {
            model.choose(group.id, group.items.contains { $0.path == fixture.path }
                ? parentSide : (parentSide == .thisMachine ? .otherMachine : .thisMachine))
        }
        await model.applyAndReport(container: fixture.contextB.container)
        guard case .ready = model.phase else { return XCTFail("Keep the picks visible after refusing") }
        XCTAssertEqual(model.selectionError,
            "These picks don’t fit together. Choose the same Mac for \(fixture.path) and its contents.")
        XCTAssertFalse(fixture.git.isRebaseInProgress(at: fixture.storeB))
        XCTAssertEqual(try fixture.files.readFile(at: fixture.storeB + "/" + fixture.path), "local",
                       "Incompatible picks must not commit either deletion, parent=\(parentSide)")
    }

    func assertMirrorLayout() async throws {
        for side in [ConflictSide.thisMachine, .otherMachine] {
            let fixture = try NativeTestWork.run {
                try SyncConflictByteFixture(name: "file-folder", initial: .file(Data("base".utf8)),
                    this: .folderWith(["keep": .file(Data("local child".utf8))]), other: .file(self.pickedBytes))
            }
            defer { try? fixture.files.deleteDirectory(at: fixture.root) }
            let model = try await choose(fixture, side: side)
            if side == .thisMachine {
                XCTAssertEqual(model.phase, .done)
            } else {
                guard case .ready = model.phase else { return XCTFail("The local folder needs an actionable refusal") }
                XCTAssertEqual(model.selectionError,
                    "Move the folder at \(fixture.path), then choose Other Mac again. You can also keep This Mac.")
            }
            try assertNoAuxiliary(fixture, store: fixture.storeB)
            XCTAssertEqual(try fixture.files.readFile(at: fixture.storeB + "/" + fixture.path + "/keep"), "local child")
            XCTAssertFalse(fixture.git.isRebaseInProgress(at: fixture.storeB))
        }
    }

    func assertAuxiliaryAdmission() async throws {
        let fixture = try makeFixture(link: false)
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        let change = "for auxiliary in '\(fixture.storeB)/\(fixture.path)'~*; do rm \"$auxiliary\"; "
            + "mkdir \"$auxiliary\"; printf foreign > \"$auxiliary/extra\"; done"
        let engine = try fixture.folderObservationEngine(change: change)
        let model = ConflictResolutionModel(engine: engine, git: fixture.git,
            credentials: InMemoryCredentialStore(), root: fixture.storeB, steps: SyncStepModel())
        await model.loadAndReport(container: fixture.contextB.container)
        guard case let .ready(groups) = model.phase else { return XCTFail("Conflict must load") }
        for group in groups { model.choose(group.id, .thisMachine) }
        try fixture.files.writeFile(at: fixture.root + "/folder-armed", content: "auxiliary replaced")
        await model.applyAndReport(container: fixture.contextB.container)
        XCTAssertEqual(try fixture.files.readData(at: fixture.root + "/before-abort.json"),
                       try fixture.files.readData(at: fixture.root + "/after-change.json"),
                       "Check the auxiliary occupant before removing anything from the incoming folder")
        guard case let .error(message) = model.phase else { return XCTFail("Report the auxiliary folder blocking abort") }
        XCTAssertTrue(message.contains("couldn’t return the store to rest"), message)
        let parent = fixture.storeB + "/skills/conflict/assets"
        for name in try fixture.files.listDirectory(at: parent) where name.utf8.starts(with: "file-folder~".utf8) {
            XCTAssertEqual(try fixture.files.readFile(at: parent + "/" + name + "/extra"), "foreign")
            try fixture.files.deleteDirectory(at: parent + "/" + name)
        }
        try fixture.files.deleteFile(at: fixture.root + "/folder-armed")
        await model.loadAndReport(container: fixture.contextB.container)
        guard case .ready = model.phase else { return XCTFail("Recover once the external auxiliary folder is moved") }
        XCTAssertFalse(fixture.git.isRebaseInProgress(at: fixture.storeB))
    }
    func assertPartialIndexFailure() async throws {
        let fixture = try makeFixture(link: false)
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        let engine = try fixture.folderObservationEngine(change: ":", failIndexRemoval: true)
        let model = ConflictResolutionModel(engine: engine, git: fixture.git,
            credentials: InMemoryCredentialStore(), root: fixture.storeB, steps: SyncStepModel())
        await model.loadAndReport(container: fixture.contextB.container)
        guard case let .ready(groups) = model.phase else { return XCTFail("Conflict must load") }
        for group in groups { model.choose(group.id, .thisMachine) }
        try fixture.files.writeFile(at: fixture.root + "/folder-armed", content: "partial index failure")
        await model.applyAndReport(container: fixture.contextB.container)
        guard case let .error(message) = model.phase else { return XCTFail("Report the failed index write") }
        XCTAssertTrue(message.contains("fixture failure after native index removal"))
        XCTAssertEqual(try fixture.files.readData(at: fixture.root + "/before-abort.json"),
                       try fixture.files.readData(at: fixture.root + "/after-change.json"),
                       "An index failure must hand the intact folder to abort")
        XCTAssertTrue(message.contains("out of the store"), "A write error cannot authorize forced cleanup: " + message)
        XCTAssertTrue(fixture.git.isRebaseInProgress(at: fixture.storeB))
        try fixture.files.publishDirectory(at: fixture.storeB + "/" + fixture.path, to: fixture.root + "/saved-folder")
        try fixture.files.deleteFile(at: fixture.root + "/folder-armed")
        await model.loadAndReport(container: fixture.contextB.container)
        guard case .ready = model.phase else { return XCTFail("Recover after moving the partial-write obstruction") }
        XCTAssertEqual(try fixture.files.readFile(at: fixture.root + "/saved-folder/keep"), "other bytes")
        try assertChosen(fixture, link: false, stores: [fixture.storeB])
    }

    func assertAmbiguousLayout() async throws {
        let fixture = try NativeTestWork.run {
            try SyncConflictByteFixture(name: "file-folder", initial: .file(Data("base".utf8)),
                this: .folder, other: .file(self.pickedBytes))
        }
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        let auxiliary = fixture.path + "~HEAD"
        try NativeTestWork.run {
            try fixture.files.writeData(at: fixture.storeA + "/" + auxiliary, data: self.pickedBytes)
            try fixture.git.stageAllAndCommit(at: fixture.storeA, message: "second incoming file")
            try fixture.git.push(at: fixture.storeA, credential: nil)
            try fixture.files.writeFile(at: fixture.storeB + "/" + auxiliary + "/keep", content: "second folder")
            try fixture.git.stageAllAndCommit(at: fixture.storeB, message: "second local folder")
        }
        let model = ConflictResolutionModel(engine: fixture.engine, git: fixture.git,
            credentials: InMemoryCredentialStore(), root: fixture.storeB, steps: SyncStepModel())
        await model.loadAndReport(container: fixture.contextB.container)
        guard case let .ready(groups) = model.phase else { return XCTFail("Resolve overlapping candidates as one set") }
        XCTAssertEqual(Set(groups.flatMap(\.items).map(\.path)),
                       Set([fixture.path, fixture.path + "/keep", auxiliary, auxiliary + "/keep"]))
        for group in groups { model.choose(group.id, .thisMachine) }
        await model.applyAndReport(container: fixture.contextB.container)
        XCTAssertEqual(model.phase, .done)
        XCTAssertFalse(fixture.git.isRebaseInProgress(at: fixture.storeB))
        for store in try [fixture.storeB, fixture.freshClone()] {
            XCTAssertEqual(Set(try fixture.files.listDirectory(at: store + "/skills/conflict/assets")),
                           Set(["file-folder", "file-folder~HEAD"]))
            XCTAssertEqual(try fixture.files.readFile(at: store + "/" + fixture.path + "/keep"), "chosen folder bytes")
            XCTAssertEqual(try fixture.files.readFile(at: store + "/" + auxiliary + "/keep"), "second folder")
        }
    }

    func assertFolderRestoreThroughFile() async throws {
        let fixture = try makeFixture(link: false)
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        let folder = fixture.storeB + "/" + fixture.path
        let engine = try fixture.folderObservationEngine(change: ":",
            afterRemovalChange: "rm -rf '\(folder)'; printf transient > '\(folder)'")
        let model = ConflictResolutionModel(engine: engine, git: fixture.git,
            credentials: InMemoryCredentialStore(), root: fixture.storeB, steps: SyncStepModel())
        await model.loadAndReport(container: fixture.contextB.container)
        guard case let .ready(groups) = model.phase else { return XCTFail("Conflict must load") }
        for group in groups { model.choose(group.id, .otherMachine) }
        try fixture.files.writeFile(at: fixture.root + "/folder-armed", content: "parent became a file")
        await model.applyAndReport(container: fixture.contextB.container)
        XCTAssertEqual(model.phase, .done, "Native checkout can restore children through a regular parent occupant")
        XCTAssertEqual(try fixture.files.readFile(at: folder + "/nested/keep"), "nested bytes")
        try assertNoAuxiliary(fixture, store: fixture.storeB)
        XCTAssertFalse(fixture.git.isRebaseInProgress(at: fixture.storeB))
    }

}
