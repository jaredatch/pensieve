import XCTest
@testable import Pensieve

extension SyncConflictResolutionTests {
    @MainActor
    func testConcurrentRetirementsUnionWithoutUserConflictForEitherPick() throws {
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
                for path in paths { XCTAssertFalse(tree.contains(path + "/keep"), "R5: both retirements must survive \(side)") }
            } catch { XCTFail("R5: \(side): \(error)") }
        }
    }

    @MainActor
    func testOlderWriterPreservesRetirementWithoutRuleChurn() throws {
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
            // The older build's ensureSyncAttributes and native staging/rebase/push sequence.
            try fixture.files.writeFile(at: older + "/.gitattributes", content: attributes)
            try fixture.files.writeFile(at: older + "/.gitignore", content: ".DS_Store\n")
            try fixture.git.runOrThrow(["-C", older, "add", "-A"], in: nil)
            XCTAssertEqual(try fixture.git.run(["-C", older, "diff", "--cached", "--quiet"], in: nil).exit, 0,
                           "R4: older preparation must have nothing to commit")
            _ = try fixture.git.pullRebase(at: older, credential: nil)
            try fixture.git.push(at: older, credential: nil)
            _ = try fixture.engine.sync(root: fixture.storeB, message: "current writer", credential: nil,
                                        context: fixture.contextB)
        }
        XCTAssertEqual(try fixture.git.runOrThrow(["--git-dir", fixture.remote, "rev-parse", "main"], in: nil).stdout,
                       original, "R4: the two builds must not alternate commits")
        XCTAssertEqual(try fixture.files.readFile(at: fixture.storeB + "/.gitattributes"), attributes)
        try fixture.files.writeFile(at: older + "/" + item.path + "/older-child", content: "older local work")
        try fixture.git.runOrThrow(["-C", older, "add", "-A"], in: nil)
        let staged = try fixture.git.runOrThrow(["-C", older, "diff", "--cached", "--name-only"], in: nil).stdout
        XCTAssertTrue(staged.contains(item.path + "/older-child"), "The older writer still stages its ordinary local files")
        XCTAssertFalse(staged.contains(".pensieve-retired-paths"), "The older writer does not erase the receipt")
        try fixture.files.writeFile(at: fixture.storeB + "/" + item.path + "/keep", content: "retired child")
        _ = try fixture.engine.sync(root: fixture.storeB, message: "still retired", credential: nil, context: fixture.contextB)
        XCTAssertTrue(try fixture.git.runOrThrow(["--git-dir", fixture.remote, "ls-tree", "-r", "main", "--", item.path],
                                               in: nil).stdout.isEmpty)
    }

    @MainActor
    func assertThisFileAgainstRemoteGitlink() throws {
        for side in [ConflictSide.thisMachine, .otherMachine] {
            let bytes = Data("this file must sync".utf8)
            let fixture = try SyncConflictByteFixture.gitlinkConflict(fileOnThisMachine: bytes)
            defer { try? fixture.files.deleteDirectory(at: fixture.root) }
            let item = try fixture.inspect()
            do {
                _ = try fixture.engine.resolveConflicts(root: fixture.storeB,
                    picks: [item.path: ResolutionPick(side: side, expectedThis: item.thisMachine,
                        expectedOther: item.otherMachine, expectedThisUnavailable: item.thisUnavailable,
                        expectedOtherUnavailable: item.otherUnavailable, expectedThisMode: item.thisMode,
                        expectedOtherMode: item.otherMode)], credential: nil, context: fixture.contextB)
                if side == .thisMachine { try fixture.assertPublished(bytes) } else {
                    let tree = try fixture.git.runData(["--git-dir", fixture.remote, "ls-tree", "-r", "main",
                                                       "--", item.path], in: nil)
                    XCTAssertTrue(tree.stdout.isEmpty)
                }
            } catch { XCTFail("Remote gitlink, pick \(side): \(error)") }
        }
    }

}
