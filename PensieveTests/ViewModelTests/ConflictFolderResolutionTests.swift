import XCTest
@testable import Pensieve

@MainActor
final class ConflictFolderResolutionTests: XCTestCase {
    let pickedBytes = Data([0, 255, 13, 10, 42])
    let pickedLink = "../kept-link"

    func testThisMacFileReplacesTrackedFolderAndPushesToFreshClone() async throws {
        try await assertRootTildeConflict()
        try await assertIncompatiblePicks()
        let fixture = try makeFixture(link: false)
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        let model = try await choose(fixture, side: .thisMachine)
        XCTAssertEqual(model.phase, .done, "The file pick must finish sync")
        XCTAssertNil(model.selectionError)
        try assertChosen(fixture, link: false, stores: [fixture.storeB, fixture.freshClone()])
    }

    func testThisMacSymlinkReplacesFolderInOnePassAndPushesToFreshClone() async throws {
        let fixture = try makeFixture(link: true)
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        let model = try await choose(fixture, side: .thisMachine)
        XCTAssertEqual(model.phase, .done, "One Apply must finish, not re-inspect the identical conflict")
        XCTAssertNil(model.selectionError)
        try assertChosen(fixture, link: true, stores: [fixture.storeB, fixture.freshClone()])
    }

    func testRefusedFilePickPreservesTopLevelEntriesUntilAbort() async throws {
        try await assertRefusals(link: false, nested: false)
    }

    func testUnrelatedIndexLockPreservesRefusedFolderUntilRecovery() async throws {
        for extra in [false, true] { try await assertUnrelatedAbortFailure(extra: extra) }
    }

    func testAuxiliaryFolderBlockingAbortReportsFailureAndRecovers() async throws {
        try await assertAuxiliaryAdmission()
    }

    func testPartialIndexWriteFailureHandsIntactFolderToAbort() async throws {
        try await assertPartialIndexFailure()
    }

    func testInspectionAbortFailureReportsRefusalOnce() async throws {
        try await assertInspectionAbortRefusal()
    }

    func testVanishedAbortProofPreservesGitRefusal() async throws {
        try await assertAbortProofFailure()
    }

    func testRefusedFilePickPreservesNestedEntriesUntilAbort() async throws {
        try await assertRefusals(link: false, nested: true)
    }

    func testRefusedAbortWithUnreadableOrigHeadReportsRefusal() async throws {
        for occupant in ["link", "oversized", "FIFO", "missing"] {
            let failures = testRun?.failureCount
            try await assertUnreadableOrigHeadReportsRefusal(occupant)
            if testRun?.failureCount != failures { return }
        }
    }

    func testRefusedSymlinkPickPreservesTopLevelEntriesUntilAbort() async throws {
        try await assertRefusals(link: true, nested: false)
    }

    func testRefusedSymlinkPickPreservesNestedEntriesUntilAbort() async throws {
        try await assertRefusals(link: true, nested: true)
    }

    func testOtherMacPickKeepsFolderAndItsTrackedEntries() async throws {
        try await assertMirrorLayout()
        try await assertAmbiguousLayout()
        try await assertFolderRestoreThroughFile()
        for link in [false, true] {
            let fixture = try makeFixture(link: link)
            defer { try? fixture.files.deleteDirectory(at: fixture.root) }
            let model = try await choose(fixture, side: .otherMachine)
            XCTAssertEqual(model.phase, .done)
            for store in try [fixture.storeB, fixture.freshClone()] {
                try assertNoAuxiliary(fixture, store: store)
                let folder = store + "/" + fixture.path
                XCTAssertEqual(try fixture.files.entryTypeWithoutFollowingLinks(at: folder), .directory)
                XCTAssertEqual(try fixture.files.readData(at: folder + "/keep"), Data("other bytes".utf8))
                XCTAssertEqual(try fixture.files.readData(at: folder + "/nested/keep"), Data("nested bytes".utf8))
            }
            XCTAssertFalse(fixture.git.isRebaseInProgress(at: fixture.storeB))
        }
    }

    func testFolderReplacementUnlinksChildrenWithoutTouchingTheirTargets() async throws {
        for link in [false, true] {
            let fixture = try makeFixture(link: link, links: true)
            defer { try? fixture.files.deleteDirectory(at: fixture.root) }
            try fixture.files.writeFile(at: fixture.root + "/outside", content: "outside bytes")
            try fixture.files.writeFile(at: fixture.storeB + "/skills/conflict/inside", content: "inside bytes")
            let model = try await choose(fixture, side: .thisMachine)
            XCTAssertEqual(model.phase, .done)
            XCTAssertEqual(try fixture.files.readFile(at: fixture.root + "/outside"), "outside bytes")
            XCTAssertEqual(try fixture.files.readFile(at: fixture.storeB + "/skills/conflict/inside"), "inside bytes")
            try assertChosen(fixture, link: link, stores: [fixture.storeB, fixture.freshClone()])
        }
    }

    func makeFixture(link: Bool, links: Bool = false, kind: String = "file") throws -> SyncConflictByteFixture {
        let this: SyncConflictByteFixture.Entry = link ? .symlink(pickedLink) : .file(pickedBytes)
        var children: [String: SyncConflictByteFixture.Entry] = [
            "keep": .file(Data("other bytes".utf8)), "nested/keep": .file(Data("nested bytes".utf8))
        ]
        for (name, bytes) in [("keep", Data("other bytes".utf8)), ("nested/keep", Data("nested bytes".utf8))] {
            if kind == "executable" { children[name] = .executable(bytes) }
            if kind == "symlink" { children[name] = .symlink("../kept-link") }
        }
        if links {
            children["outward"] = .symlink("../../../../../outside")
            children["nested/inward"] = .symlink("../../../inside")
        }
        return try NativeTestWork.run {
            try SyncConflictByteFixture(name: "file-folder", initial: .file(Data("base".utf8)),
                                        this: this, other: .folderWith(children))
        }
    }

    func choose(_ fixture: SyncConflictByteFixture, side: ConflictSide) async throws -> ConflictResolutionModel {
        let model = ConflictResolutionModel(engine: fixture.engine, git: fixture.git,
            credentials: InMemoryCredentialStore(), root: fixture.storeB, steps: SyncStepModel())
        await model.loadAndReport(container: fixture.contextB.container)
        guard case let .ready(groups) = model.phase else {
            XCTFail("The real conflict must load"); return model
        }
        XCTAssertEqual(groups.flatMap(\.items).map(\.path).sorted(), fixture.expectedPaths.sorted())
        for group in groups { model.choose(group.id, side) }
        await model.applyAndReport(container: fixture.contextB.container)
        return model
    }

    func assertNoAuxiliary(_ fixture: SyncConflictByteFixture, store: String) throws {
        let names = try fixture.files.listDirectory(at: store + "/skills/conflict/assets")
        XCTAssertEqual(names, ["file-folder"], "Git's auxiliary conflict file must leave no residue")
    }

    func assertChosen(_ fixture: SyncConflictByteFixture, link: Bool, stores: [String]) throws {
        for store in stores {
            try assertNoAuxiliary(fixture, store: store)
            let full = store + "/" + fixture.path
            if link {
                XCTAssertEqual(try fixture.files.entryTypeWithoutFollowingLinks(at: full), .symlink)
                XCTAssertEqual(try fixture.files.symlinkTarget(at: full), pickedLink)
            } else {
                XCTAssertEqual(try fixture.files.entryTypeWithoutFollowingLinks(at: full), .regular)
                XCTAssertEqual(try fixture.files.readData(at: full), pickedBytes)
            }
        }
        XCTAssertFalse(fixture.git.isRebaseInProgress(at: fixture.storeB))
    }

    func assertRefusals(link: Bool, nested: Bool) async throws {
        let types = ["file", "executable", "symlink"]
        let cases = ["extra-file", "empty-folder", "changed-bytes", "unreadable"]
            + types.flatMap { from in types.filter { $0 != from }.map { from + "-to-" + $0 } }
        for fault in cases {
            try await assertRefusal(link: link, nested: nested, fault: fault)
        }
    }

    func assertRefusal(link: Bool, nested: Bool, fault: String) async throws {
        let kind = fault.components(separatedBy: "-to-").first ?? "file"
        let fixture = try makeFixture(link: link, links: true, kind: kind)
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        let directory = fixture.storeB + "/" + fixture.path + (nested ? "/nested" : "")
        let change = (fault == "extra-file"
            ? "/usr/bin/git -C '\(fixture.storeB)' update-ref ORIG_HEAD HEAD; " : "")
            + mutation(fault, directory: directory)
            + "; printf outside > '\(fixture.root)/outside'"
            + "; printf inside > '\(fixture.storeB)/skills/conflict/inside'"
            + "; mkdir '\(fixture.storeB)/unrelated'; printf sibling > '\(fixture.storeB)/unrelated/keep'"
        let engine = try fixture.folderObservationEngine(change: change, warnOnAbort: fault == "extra-file")
        let model = ConflictResolutionModel(engine: engine, git: fixture.git,
            credentials: InMemoryCredentialStore(), root: fixture.storeB, steps: SyncStepModel())
        await model.loadAndReport(container: fixture.contextB.container)
        guard case let .ready(groups) = model.phase else { return XCTFail("Conflict must load for \(fault)") }
        for group in groups { model.choose(group.id, .thisMachine) }
        try fixture.files.writeFile(at: fixture.root + "/folder-armed", content: fault)
        await model.applyAndReport(container: fixture.contextB.container)
        guard case .ready = model.phase else {
            return XCTFail("Must refuse \(fault), link=\(link), nested=\(nested): \(model.phase)")
        }
        XCTAssertEqual(model.selectionError,
            "Pensieve can’t replace the folder at \(fixture.path). Choose the other version to finish syncing.", fault)
        let before = try fixture.files.readData(at: fixture.root + "/after-change.json")
        let atAbort = try fixture.files.readData(at: fixture.root + "/before-abort.json")
        XCTAssertEqual(atAbort, before, "Refusal must preserve entries until abort: \(fault)")
        XCTAssertEqual(try fixture.files.readFile(at: fixture.root + "/abort-results"),
                       fault == "extra-file" ? "128\n0\n" : "0\n", "Native abort first; retry only on refusal: \(fault)")
        XCTAssertEqual(try fixture.files.readFile(at: fixture.root + "/outside"), "outside", fault)
        XCTAssertEqual(try fixture.files.readFile(at: fixture.storeB + "/skills/conflict/inside"), "inside", fault)
        XCTAssertEqual(try fixture.files.readFile(at: fixture.storeB + "/unrelated/keep"), "sibling", fault)
        XCTAssertFalse(fixture.git.isRebaseInProgress(at: fixture.storeB), "Abort must finish after \(fault)")
        try assertChosen(fixture, link: link, stores: [fixture.storeB])
    }

    func assertUnrelatedAbortFailure(extra: Bool) async throws {
        let fixture = try makeFixture(link: false, links: true)
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        let folder = fixture.storeB + "/" + fixture.path
        let change = "printf changed > '\(folder)/keep'" + (extra ? "; printf extra > '\(folder)/extra'" : "")
        let engine = try fixture.folderObservationEngine(change: change, lockAbort: true)
        let model = ConflictResolutionModel(engine: engine, git: fixture.git,
            credentials: InMemoryCredentialStore(), root: fixture.storeB, steps: SyncStepModel())
        await model.loadAndReport(container: fixture.contextB.container)
        guard case let .ready(groups) = model.phase else { return XCTFail("Conflict must load before locked abort") }
        for group in groups { model.choose(group.id, .thisMachine) }
        try fixture.files.writeFile(at: fixture.root + "/folder-armed", content: "locked abort")
        await model.applyAndReport(container: fixture.contextB.container)
        XCTAssertEqual(try fixture.files.entryTypeWithoutFollowingLinks(at: folder), .directory,
                       "An unrelated index lock must not authorize deleting the refused folder")
        XCTAssertEqual(try fixture.files.readFile(at: folder + "/keep"), "changed")
        if extra { XCTAssertEqual(try fixture.files.readFile(at: folder + "/extra"), "extra") }
        XCTAssertEqual(try fixture.files.readData(at: fixture.root + "/before-abort.json"),
                       try fixture.files.readData(at: fixture.root + "/after-change.json"))
        XCTAssertEqual(try fixture.files.readFile(at: fixture.root + "/abort-results"), "128\n",
                       "A lock failure must not cause destructive cleanup or another abort")
        guard case let .error(message) = model.phase else { return XCTFail("Abort failure must be reported") }
        XCTAssertTrue(message.contains("can’t replace the folder"), "Keep the original refusal")
        XCTAssertTrue(message.contains("couldn’t return the store to rest"), "Report the unfinished abort")
        // A later operation must preserve files added after the refused resolve.
        try fixture.files.deleteFile(at: fixture.storeB + "/.git/index.lock")
        try fixture.files.deleteFile(at: fixture.root + "/folder-armed")
        if extra { try await assertLaterAbortPreservesFolder(fixture, model: model) }
        await model.loadAndReport(container: fixture.contextB.container)
        guard case .ready = model.phase else { return XCTFail("Next inspection must recover after the blocking folder is moved") }
        try assertChosen(fixture, link: false, stores: [fixture.storeB])
    }

    func mutation(_ fault: String, directory: String) -> String {
        switch fault {
        case "extra-file": return "printf extra > '\(directory)/extra'"
        case "empty-folder": return "mkdir '\(directory)/empty'"
        case "changed-bytes": return "printf changed > '\(directory)/keep'"
        case "unreadable": return "chmod 000 '\(directory)/keep'"
        default:
            let target = fault.components(separatedBy: "-to-")[1]
            if target == "symlink" { return "rm '\(directory)/keep'; ln -s ../kept-link '\(directory)/keep'" }
            if fault.hasPrefix("symlink-to-") {
                return "rm '\(directory)/keep'; printf '../kept-link' > '\(directory)/keep'; "
                    + "chmod \(target == "file" ? "644" : "755") '\(directory)/keep'"
            }
            return "chmod \(target == "file" ? "644" : "755") '\(directory)/keep'"
        }
    }
}
