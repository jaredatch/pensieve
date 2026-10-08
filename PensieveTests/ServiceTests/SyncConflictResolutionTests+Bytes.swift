import XCTest
@testable import Pensieve

extension SyncConflictResolutionTests {
    @MainActor
    func testBinaryAndUTF16PicksKeepExactBytesAcrossRemoteAndFreshClone() throws {
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
    func testBinaryAndUTF16DriftRefusesStalePicksAndLeavesRemoteUnchanged() throws {
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
