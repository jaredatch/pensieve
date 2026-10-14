import XCTest
@testable import Pensieve

extension SyncConflictResolutionTests {
    func testConcurrentRetirementsUnionWithoutUserConflictForEitherPick() throws {
        try NativeTestWork.run { [self] in
            for side in [ConflictSide.thisMachine, .otherMachine] {
                let payload = SyncConflictByteFixture.payloads[0]
                let fixture = try SyncConflictByteFixture(name: payload.name, this: payload.this, other: payload.other)
                defer { try? fixture.files.deleteDirectory(at: fixture.root) }
                let paths = ["skills/conflict/assets/retired-a", "skills/conflict/assets/retired-b"]
                for (store, path) in zip([fixture.storeA, fixture.storeB], paths) {
                    try fixture.git.retireConflictPath(path, at: store)
                    try fixture.git.stageAllAndCommit(at: store, message: "independent retirement")
                }
                try fixture.git.push(at: fixture.storeA, credential: nil)
                let item = try fixture.inspect()
                do {
                    _ = try fixture.engine.resolveConflicts(root: fixture.storeB,
                        picks: [item.path: ResolutionPick(side: side, expectedThis: item.thisMachine,
                            expectedOther: item.otherMachine, expectedThisMode: item.thisMode,
                            expectedOtherMode: item.otherMode)], credential: nil, context: fixture.contextB)
                    let fresh = fixture.root + "/receipt-fresh"
                    try fixture.git.clone(remote: "file://" + fixture.remote, into: fresh, credential: nil)
                    for path in paths { try fixture.files.writeFile(at: fresh + "/" + path + "/keep", content: "local only") }
                    try fixture.git.stageAllAndCommit(at: fresh, message: "receipt union probe")
                    let tree = try fixture.git.runOrThrow(["-C", fresh, "ls-files"], in: nil).stdout
                    for path in paths { XCTAssertFalse(tree.contains(path + "/keep"),
                        "R5: both retirements must survive \(side)") }
                } catch { XCTFail("R5: \(side): \(error)") }
            }
        }
    }

    func testOlderWriterPreservesRetirementDuringRuleChurn() throws {
        try NativeTestWork.run { [self] in
            let fixture = try SyncConflictByteFixture.gitlinkConflict()
            defer { try? fixture.files.deleteDirectory(at: fixture.root) }
            let item = try fixture.inspect()
            _ = try fixture.engine.resolveConflicts(root: fixture.storeB,
                picks: [item.path: ResolutionPick(side: .thisMachine, expectedThis: item.thisMachine,
                    expectedOther: item.otherMachine, expectedThisUnavailable: item.thisUnavailable,
                    expectedOtherUnavailable: item.otherUnavailable)], credential: nil, context: fixture.contextB)
            let older = fixture.root + "/older"
            try fixture.git.clone(remote: "file://" + fixture.remote, into: older, credential: nil)
            let attributes = "manifest/categories/*.yaml merge=union\nmanifest/scenarios/*.yaml merge=union\n"
                + "manifest/projects.yaml merge=union\n"
            let original = try fixture.git.runOrThrow(["--git-dir", fixture.remote, "rev-parse", "main"], in: nil).stdout
            for _ in 0..<2 {
                _ = try fixture.git.pullRebase(at: older, credential: nil)
                // The older build's ensureSyncAttributes and native staging/rebase/push sequence.
                try fixture.files.writeFile(at: older + "/.gitattributes", content: attributes)
                try fixture.files.writeFile(at: older + "/.gitignore", content: ".DS_Store\n")
                XCTAssertTrue(try fixture.git.stageAllAndCommit(at: older, message: "older attributes"))
                _ = try fixture.git.pullRebase(at: older, credential: nil)
                try fixture.git.push(at: older, credential: nil)
                let ingested = try fixture.engine.sync(root: fixture.storeB, message: "current writer", credential: nil,
                                                       context: fixture.contextB)
                guard case .synced = ingested else { return XCTFail("Current writer stopped: \(ingested)") }
                XCTAssertEqual(try fixture.engine.sync(root: fixture.storeB, message: "current attributes", credential: nil,
                                                      context: fixture.contextB), .synced(pushed: true, warnings: []))
            }
            XCTAssertNotEqual(try fixture.git.runOrThrow(["--git-dir", fixture.remote, "rev-parse", "main"], in: nil).stdout,
                              original, "Both builds publish their attributes while preserving retirement")
            XCTAssertEqual(try fixture.files.readFile(at: fixture.storeB + "/.gitattributes"),
                           "manifest/categories/*.yaml merge=union\nmanifest/projects.yaml merge=union\n")
            try fixture.files.writeFile(at: older + "/" + item.path + "/older-child", content: "older local work")
            try fixture.git.runOrThrow(["-C", older, "add", "-A"], in: nil)
            let staged = try fixture.git.runOrThrow(["-C", older, "diff", "--cached", "--name-only"], in: nil).stdout
            XCTAssertTrue(staged.contains(item.path + "/older-child"), "The older writer still stages its ordinary local files")
            XCTAssertFalse(staged.contains(".pensieve-retired-paths"), "The older writer does not erase the receipt")
            try fixture.files.writeFile(at: fixture.storeB + "/" + item.path + "/keep", content: "retired child")
            _ = try fixture.engine.sync(root: fixture.storeB, message: "still retired", credential: nil,
                context: fixture.contextB)
            XCTAssertTrue(try fixture.git.runOrThrow(["--git-dir", fixture.remote, "ls-tree", "-r", "main", "--", item.path],
                                                   in: nil).stdout.isEmpty)
        }
    }

    func testProtectedSkillRootGitlinksCannotRetireAndFolderPickStillSyncs() throws {
        try NativeTestWork.run { [self] in
            for both in [false, true] { try assertProtectedGitlinkChoices(both: both) }
            for leaf in [false, true] { try assertProtectedGitlinkDeletion(leaf: leaf) }
        }
    }

    private func assertProtectedGitlinkChoices(both: Bool) throws {
        for changedOnThisMac in [false, true] {
            let fixture = try SyncConflictByteFixture.gitlinkConflict(both: both,
                otherEntry: both ? nil : .folder, changedEntryOnThisMachine: changedOnThisMac, skillRoot: true)
            defer { try? fixture.files.deleteDirectory(at: fixture.root) }
            let items = try fixture.inspectAll()
            let rootItem = try XCTUnwrap(items.first { $0.path == fixture.path })
            let nestedSide: ConflictSide = changedOnThisMac ? .otherMachine : .thisMachine
            let unavailable = nestedSide == .thisMachine ? rootItem.thisUnavailable : rootItem.otherUnavailable
            XCTAssertEqual(unavailable?.canChoose, false, "A skill-root gitlink must be unavailable")
            let remote = try fixture.git.runOrThrow(["--git-dir", fixture.remote, "rev-parse", "main"], in: nil).stdout
            func picks(_ side: ConflictSide) -> [String: ResolutionPick] {
                Dictionary(uniqueKeysWithValues: items.map { item in
                    (item.path, ResolutionPick(side: side, expectedThis: item.thisMachine,
                        expectedOther: item.otherMachine, expectedThisUnavailable: item.thisUnavailable,
                        expectedOtherUnavailable: item.otherUnavailable, expectedThisMode: item.thisMode,
                        expectedOtherMode: item.otherMode))
                })
            }
            XCTAssertThrowsError(try fixture.engine.resolveConflicts(root: fixture.storeB,
                picks: picks(nestedSide), credential: nil, context: fixture.contextB)) {
                XCTAssertEqual($0.localizedDescription, both
                    ? "Pensieve can’t resolve this conflict. Resolve it in git: " + fixture.path
                    : "Pensieve can’t sync the nested repository at " + fixture.path + ". Choose the other version.")
            }
            XCTAssertEqual(try fixture.git.runOrThrow(["--git-dir", fixture.remote, "rev-parse", "main"], in: nil).stdout,
                           remote)
            if both {
                let otherSide: ConflictSide = nestedSide == .thisMachine ? .otherMachine : .thisMachine
                XCTAssertThrowsError(try fixture.engine.resolveConflicts(root: fixture.storeB,
                    picks: picks(otherSide), credential: nil, context: fixture.contextB)) {
                    XCTAssertEqual($0.localizedDescription,
                        "Pensieve can’t resolve this conflict. Resolve it in git: " + fixture.path)
                }
            } else {
                let folderSide: ConflictSide = nestedSide == .thisMachine ? .otherMachine : .thisMachine
                _ = try fixture.engine.resolveConflicts(root: fixture.storeB,
                    picks: picks(folderSide), credential: nil, context: fixture.contextB)
                let kept = try fixture.git.runData(["--git-dir", fixture.remote, "show",
                    "main:" + fixture.path + "/keep"], in: nil)
                XCTAssertEqual(kept.exit, 0)
                XCTAssertEqual(kept.stdout, Data("chosen folder bytes".utf8))
            }
            XCTAssertTrue(try StoreIgnoreRules.retiredPaths(at: fixture.storeB, files: fixture.files).isEmpty)
            XCTAssertFalse(fixture.files.fileExists(at: fixture.storeB + "/.pensieve-retired-paths"),
                           "Protected conflicts must write no receipt, including one the reader would ignore")
            XCTAssertNotEqual(try fixture.git.runData(["--git-dir", fixture.remote, "show",
                "main:.pensieve-retired-paths"], in: nil).exit, 0)
            XCTAssertFalse(fixture.git.isRebaseInProgress(at: fixture.storeB))
        }
    }

    private func assertProtectedGitlinkDeletion(leaf: Bool) throws {
        let fixture = try SyncConflictByteFixture.gitlinkConflict(skillRoot: true)
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        let full = fixture.storeB + "/" + fixture.path
        try fixture.git.initRepository(at: full)
        try fixture.files.writeFile(at: full + "/keep", content: "nested base")
        try fixture.git.stageAllAndCommit(at: full, message: "nested repository")
        let item = try fixture.inspect()
        try fixture.files.writeFile(at: fixture.root + "/resolution-marker", content: "uncommitted nested work")
        if leaf { try fixture.files.writeFile(at: fixture.root + "/resolution-leaf", content: "delete this leaf") }
        let engine = try fixture.protectedDeletionEngine()
        _ = try engine.resolveConflicts(root: fixture.storeB,
            picks: [item.path: ResolutionPick(side: .otherMachine, expectedThis: item.thisMachine,
                expectedOther: item.otherMachine, expectedThisUnavailable: item.thisUnavailable,
                expectedOtherUnavailable: item.otherUnavailable, expectedThisMode: item.thisMode,
                expectedOtherMode: item.otherMode)], credential: nil, context: fixture.contextB)
        if leaf {
            XCTAssertNil(try fixture.files.entryTypeWithoutFollowingLinks(at: full), "The deletion pick removes a file leaf")
            XCTAssertEqual(try fixture.files.readFile(at: fixture.root + "/displaced-repository/keep"),
                           "uncommitted nested work")
        } else {
            XCTAssertEqual(try fixture.files.entryTypeWithoutFollowingLinks(at: full), .directory)
            XCTAssertTrue(fixture.files.directoryExists(at: full + "/.git"))
            XCTAssertEqual(try fixture.files.readFile(at: full + "/keep"), "uncommitted nested work")
            try fixture.files.writeFile(at: full + "/notes.md", content: "new nested note")
            XCTAssertFalse(try fixture.git.stageAllAndCommit(at: fixture.storeB, message: "nested checkout stays local"))
            XCTAssertEqual(try fixture.files.readFile(at: full + "/notes.md"), "new nested note")
        }
        XCTAssertTrue(try fixture.git.runOrThrow(["--git-dir", fixture.remote, "ls-tree", "main", "--", item.path],
                                               in: nil).stdout.isEmpty)
        XCTAssertNil(try fixture.files.entryTypeWithoutFollowingLinks(at: fixture.storeB + "/.pensieve-retired-paths"))
        XCTAssertNotEqual(try fixture.git.runData(["--git-dir", fixture.remote, "show",
            "main:.pensieve-retired-paths"], in: nil).exit, 0)
        XCTAssertFalse(fixture.git.isRebaseInProgress(at: fixture.storeB))
    }

    func assertGitlinkRetirement(both: Bool, side: ConflictSide, skillRoot: Bool) throws {
        let fixture = try SyncConflictByteFixture.gitlinkConflict(both: both, skillRoot: skillRoot)
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        let nested = fixture.storeB + "/" + fixture.path
        try fixture.git.initRepository(at: nested)
        try fixture.files.writeFile(at: nested + "/committed", content: "nested checkout")
        try fixture.git.stageAllAndCommit(at: nested, message: "nested base")
        try fixture.files.writeFile(at: nested + "/committed", content: "uncommitted work")
        let downstream = fixture.root + "/downstream"
        try fixture.git.clone(remote: "file://" + fixture.remote, into: downstream, credential: nil)
        let downstreamNested = downstream + "/" + fixture.path
        try fixture.files.createDirectory(at: downstreamNested)
        let downstreamHasRepository = side == .thisMachine
        if downstreamHasRepository { try fixture.git.initRepository(at: downstreamNested) }
        try fixture.files.writeFile(at: downstreamNested + "/keep", content: "downstream work")
        let item = try fixture.inspect()
        let stale = UnavailableConflictSide(mode: "160000", objectID: String(repeating: "0", count: 40))
        XCTAssertThrowsError(try fixture.engine.resolveConflicts(root: fixture.storeB,
            picks: [item.path: ResolutionPick(side: side, expectedThis: item.thisMachine,
                expectedOther: item.otherMachine, expectedThisUnavailable: stale,
                expectedOtherUnavailable: item.otherUnavailable)], credential: nil, context: fixture.contextB)) {
            XCTAssertEqual($0 as? SyncError, .conflictsChanged)
        }
        _ = try fixture.engine.resolveConflicts(root: fixture.storeB,
            picks: [item.path: ResolutionPick(side: side, expectedThis: item.thisMachine,
                expectedOther: item.otherMachine, expectedThisUnavailable: item.thisUnavailable,
                expectedOtherUnavailable: item.otherUnavailable)], credential: nil, context: fixture.contextB)
        XCTAssertEqual(try fixture.files.readFile(at: nested + "/committed"), "uncommitted work")
        XCTAssertTrue(fixture.files.directoryExists(at: nested + "/.git"))
        let tree = try fixture.git.runData(["--git-dir", fixture.remote, "ls-tree", "main", "--", item.path], in: nil)
        XCTAssertTrue(tree.stdout.isEmpty, "Either pick retires the gitlink from sync")
        _ = try fixture.git.fastForwardOnly(at: downstream, credential: nil)
        XCTAssertEqual(try fixture.files.readFile(at: downstreamNested + "/keep"), "downstream work")
        if downstreamHasRepository {
            XCTAssertTrue(fixture.files.directoryExists(at: downstreamNested + "/.git"))
        }
        _ = try fixture.engine.sync(root: downstream, message: "sync after gitlink retirement", credential: nil,
                                    context: fixture.contextB)
        XCTAssertEqual(try fixture.files.readFile(at: downstreamNested + "/keep"), "downstream work")
        let afterSync = try fixture.git.runData(
            ["--git-dir", fixture.remote, "ls-tree", "-r", "main", "--", item.path], in: nil)
        XCTAssertTrue(afterSync.stdout.isEmpty, "A later sync must keep ordinary retired-folder children local")
    }

}
