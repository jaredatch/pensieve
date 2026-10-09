import XCTest
@testable import Pensieve

extension SyncConflictResolutionTests {
    @MainActor
    func testUnreadableGitlinkPickCannotDeleteThePathAndOtherPickStillResolves() throws {
        for both in [false, true] {
            for side in [ConflictSide.thisMachine, .otherMachine] {
                let fixture = try SyncConflictByteFixture.gitlinkConflict(both: both)
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
    }

    @MainActor
    func testBinaryAndUTF16PicksKeepExactBytesAcrossRemoteAndFreshClone() throws {
        try assertConflictEntryTypesAndModes()
        for payload in SyncConflictByteFixture.payloads {
            for side in [ConflictSide.thisMachine, .otherMachine] {
                let fixture = try SyncConflictByteFixture(name: payload.name, this: payload.this, other: payload.other)
                defer { try? fixture.files.deleteDirectory(at: fixture.root) }
                let item = try fixture.inspect()
                let outcome = try fixture.engine.resolveConflicts(root: fixture.storeB,
                    picks: [item.path: ResolutionPick(side: side, expectedThis: item.thisMachine,
                                                      expectedOther: item.otherMachine)],
                    credential: nil, context: fixture.contextB)
                guard case .synced = outcome else { return XCTFail("The pick must finish sync") }
                try fixture.assertPublished(side == .thisMachine ? payload.this : payload.other)
            }
        }
    }

    @MainActor
    private func assertConflictPreparationUsesOneCheckedFetch() throws {
        let payload = SyncConflictByteFixture.payloads[0]
        let fixture = try SyncConflictByteFixture(name: payload.name, this: payload.this, other: payload.other)
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        try fixture.files.writeFile(at: fixture.storeB + "/skills/conflict/.env", content: "protected local bytes")
        let executable = fixture.root + "/advancing-git"
        let trace = fixture.root + "/fetches"
        try fixture.files.writeExecutableFile(at: executable, content: """
            #!/bin/sh
            advance() {
                \(FakeGitScript.skipGlobalOptions)
                if [ "$1" = fetch ]; then
                    echo fetch >> '\(trace)'
                    /usr/bin/git -C '\(fixture.storeA)' -c user.name=Fixture -c user.email=fixture@example.com \
                        commit --allow-empty -m unrelated >/dev/null || exit 1
                    /usr/bin/git -C '\(fixture.storeA)' push origin main >/dev/null 2>&1 || exit 1
                fi
            }
            advance "$@"
            exec /usr/bin/git "$@"
            """ + "\n")
        let git = GitService(askpassHelperPath: fixture.root + "/askpass", executablePath: executable)
        let engine = SyncEngine(gitService: AllowlistedRemoteGit(wrapping: git), lockPath: fixture.root + "/sync.lock")
        guard case let .conflicts(set) = try engine.inspectConflicts(root: fixture.storeB, credential: nil,
                                                                   context: fixture.contextB) else {
            return XCTFail("Unrelated remote changes must leave the conflict inspectable")
        }
        XCTAssertEqual(try fixture.files.readFile(at: trace).split(separator: "\n").count, 1)
        let item = try XCTUnwrap(set.items.first)
        try fixture.files.writeFile(at: trace, content: "")
        _ = try engine.resolveConflicts(root: fixture.storeB,
            picks: [item.path: ResolutionPick(side: .thisMachine, expectedThis: item.thisMachine,
                                              expectedOther: item.otherMachine, expectedThisMode: item.thisMode,
                        expectedOtherMode: item.otherMode)], credential: nil, context: fixture.contextB)
        XCTAssertEqual(try fixture.files.readFile(at: trace).split(separator: "\n").count, 1)
        try fixture.assertPublished(payload.this)
    }

    @MainActor
    private func assertConflictEntryTypesAndModes() throws {
        for link in [false, true] {
            for side in [ConflictSide.thisMachine, .otherMachine] {
                let bytes = Data("#!/bin/sh\necho chosen\n".utf8)
                let initial: SyncConflictByteFixture.Entry = link ? .symlink("../base") : .file(Data("base".utf8))
                let this: SyncConflictByteFixture.Entry = link ? .symlink("../shared")
                    : side == .thisMachine ? .executable(bytes) : .file(Data("this edit".utf8))
                let other: SyncConflictByteFixture.Entry = link ? .symlink("../other")
                    : side == .otherMachine ? .executable(bytes) : .file(Data("other edit".utf8))
                let fixture = try SyncConflictByteFixture(name: "typed-entry", initial: initial, this: this, other: other)
                defer { try? fixture.files.deleteDirectory(at: fixture.root) }
                try fixture.git.runOrThrow(["-C", fixture.storeB, "config", "core.symlinks", "false"], in: nil)
                try fixture.git.runOrThrow(["-C", fixture.storeB, "config", "core.filemode", "false"], in: nil)
                let item = try fixture.inspect()
                _ = try fixture.engine.resolveConflicts(root: fixture.storeB,
                    picks: [item.path: ResolutionPick(side: side, expectedThis: item.thisMachine,
                        expectedOther: item.otherMachine, expectedThisMode: item.thisMode,
                        expectedOtherMode: item.otherMode)], credential: nil, context: fixture.contextB)
                let fresh = fixture.root + "/typed-fresh"
                try fixture.git.clone(remote: "file://" + fixture.remote, into: fresh, credential: nil)
                for store in [fixture.storeB, fresh] {
                    let path = store + "/" + item.path
                    if link {
                        XCTAssertTrue(fixture.files.isSymlink(at: path), "A link pick stays a link")
                        XCTAssertEqual(try fixture.files.symlinkTarget(at: path), side == .thisMachine ? "../shared" : "../other")
                    } else {
                        XCTAssertEqual(try fixture.files.readData(at: path), bytes)
                        XCTAssertTrue(fixture.files.isUserExecutableFile(at: path), "The chosen executable mode survives")
                    }
                }
            }
        }
    }

    @MainActor
    func testBinaryAndUTF16DriftRefusesStalePicksAndLeavesRemoteUnchanged() throws {
        try assertConflictPreparationUsesOneCheckedFetch()
        for payload in SyncConflictByteFixture.payloads {
            let fixture = try SyncConflictByteFixture(name: payload.name, this: payload.this, other: payload.other)
            defer { try? fixture.files.deleteDirectory(at: fixture.root) }
            let stale = try fixture.inspect()
            try fixture.change(payload.drift, at: fixture.storeA)
            _ = try fixture.engine.sync(root: fixture.storeA, message: "remote drifts", credential: nil,
                context: fixture.contextA)
            let before = try fixture.git.headSHA(at: fixture.storeA)
            XCTAssertThrowsError(try fixture.engine.resolveConflicts(root: fixture.storeB,
                picks: [stale.path: ResolutionPick(side: .thisMachine, expectedThis: stale.thisMachine,
                                                   expectedOther: stale.otherMachine)],
                credential: nil, context: fixture.contextB)) { error in
                XCTAssertEqual(error as? SyncError, .conflictsChanged)
            }
            let remote = try fixture.git.runOrThrow(["--git-dir", fixture.remote, "rev-parse", "main"], in: nil)
            XCTAssertEqual(remote.stdout.trimmingCharacters(in: .newlines), before)
            XCTAssertEqual(try fixture.files.readData(at: fixture.storeB + "/" + fixture.path), payload.this)
            XCTAssertFalse(fixture.git.isRebaseInProgress(at: fixture.storeB))
        }
    }

    @MainActor
    func testAbsentAndEmptyConflictSidesRemainDistinct() throws {
        for deletedSide in [ConflictSide.thisMachine, .otherMachine] {
            for pickSide in [ConflictSide.thisMachine, .otherMachine] {
                let fixture = try SyncConflictByteFixture(name: "empty.bin",
                    this: deletedSide == .thisMachine ? nil : Data(),
                    other: deletedSide == .otherMachine ? nil : Data())
                defer { try? fixture.files.deleteDirectory(at: fixture.root) }
                let item = try fixture.inspect()
                let absent = deletedSide == .thisMachine ? item.thisMachine : item.otherMachine
                let present = deletedSide == .thisMachine ? item.otherMachine : item.thisMachine
                XCTAssertNil(absent)
                XCTAssertTrue(try XCTUnwrap(present).isEmpty)
                _ = try fixture.engine.resolveConflicts(root: fixture.storeB,
                    picks: [item.path: ResolutionPick(side: pickSide, expectedThis: item.thisMachine,
                                                      expectedOther: item.otherMachine)],
                    credential: nil, context: fixture.contextB)
                try fixture.assertPublished(pickSide == deletedSide ? nil : Data())
            }
        }
    }
    @MainActor
    func testFailedConflictBlobReadStopsInspectionAndResolutionWithoutDeletingFiles() throws {
        for stage in [2, 3] {
            for resolving in [false, true] {
                let payload = SyncConflictByteFixture.payloads[0]
                let fixture = try SyncConflictByteFixture(name: payload.name, this: payload.this, other: payload.other)
                defer { try? fixture.files.deleteDirectory(at: fixture.root) }
                let item = try fixture.inspect()
                let executable = fixture.root + "/read-failure-git"
                let receipt = fixture.root + "/read-fault"
                try fixture.files.writeExecutableFile(at: executable, content: """
                    #!/bin/sh
                    fail_blob() {
                        \(FakeGitScript.skipGlobalOptions)
                        if [ "$1" = show ]; then
                            case "$2" in
                              :\(stage):*) touch '\(receipt)'; echo 'fixture blob read failed' >&2; exit 128 ;;
                            esac
                        fi
                    }
                    fail_blob "$@"
                    exec /usr/bin/git "$@"
                    """ + "\n")
                let faulty = GitService(askpassHelperPath: fixture.root + "/askpass", executablePath: executable)
                let engine = SyncEngine(gitService: AllowlistedRemoteGit(wrapping: faulty), lockPath: fixture.root + "/sync.lock")
                let before = try fixture.git.runOrThrow(["-C", fixture.storeB, "rev-parse", "HEAD^{tree}"], in: nil).stdout
                let remote = try fixture.git.runOrThrow(["--git-dir", fixture.remote, "rev-parse", "main"], in: nil).stdout
                XCTAssertThrowsError(try {
                    if resolving {
                        _ = try engine.resolveConflicts(root: fixture.storeB,
                            picks: [item.path: ResolutionPick(side: .thisMachine, expectedThis: item.thisMachine,
                                                              expectedOther: item.otherMachine)],
                            credential: nil, context: fixture.contextB)
                    } else {
                        _ = try engine.inspectConflicts(root: fixture.storeB, credential: nil, context: fixture.contextB)
                    }
                }()) { error in
                    guard case let GitError.commandFailed(_, code, detail, _) = error else {
                        return XCTFail("A failed blob read must be an error, never a deletion: \(error)")
                    }
                    XCTAssertEqual(code, 128)
                    XCTAssertEqual(detail.trimmingCharacters(in: .newlines), "fixture blob read failed")
                }
                XCTAssertTrue(fixture.files.fileExists(at: receipt), "This iteration must reach its read fault")
                XCTAssertEqual(try fixture.git.runOrThrow(["-C", fixture.storeB, "rev-parse", "HEAD^{tree}"], in: nil).stdout,
                               before, "Abort must restore the pre-pull tree; preparation may rewrite its commit")
                XCTAssertEqual(try fixture.files.readData(at: fixture.storeB + "/" + item.path), payload.this)
                XCTAssertEqual(try fixture.git.runOrThrow(["--git-dir", fixture.remote, "rev-parse", "main"], in: nil).stdout,
                               remote)
                XCTAssertFalse(fixture.git.isRebaseInProgress(at: fixture.storeB))
            }
        }
    }

}
