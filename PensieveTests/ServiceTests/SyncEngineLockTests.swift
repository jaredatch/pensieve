import XCTest
@testable import Pensieve

extension SyncEngineTests {
    func testBranchlessOrUnknownStoreAllEntryPointsNoMutation() throws {
        struct SignalBoom: Error {}
        for signal in [Result<Bool, Error>.success(false), .failure(SignalBoom())] {
            let context = try makeContext()
            let git = StubGit(); git.hasLocalBranchesResult = signal
            let engine = makeEngine(git: git)
            if case .failure = signal {
                XCTAssertThrowsError(try engine.sync(root: tempDir, message: "m", credential: nil, context: context))
                XCTAssertThrowsError(try engine.inspectConflicts(root: tempDir, credential: nil, context: context))
                XCTAssertThrowsError(try engine.resolveConflicts(root: tempDir, picks: [:], credential: nil, context: context))
            } else {
                XCTAssertEqual(
                    try engine.sync(root: tempDir, message: "m", credential: nil, context: context),
                    .branchless
                )
                XCTAssertEqual(
                    try engine.inspectConflicts(root: tempDir, credential: nil, context: context),
                    .conflicts(ConflictSet(items: []))
                )
                XCTAssertEqual(
                    try engine.resolveConflicts(root: tempDir, picks: [:], credential: nil, context: context),
                    .branchless
                )
            }
            XCTAssertTrue(git.calls.isEmpty, "quarantine must precede every mutating git call")
        }

        let normal = StubGit()
        _ = try makeEngine(git: normal).sync(
            root: tempDir, message: "m", credential: nil, context: makeContext()
        )
        XCTAssertTrue(normal.calls.contains("commit"), "definitely-born stores keep syncing")
    }

    func testSyncShortCircuitsUnderPreHeldLock() throws {
        let held = SyncLock.tryAcquire(at: lockPath)
        defer { held?.release() }
        XCTAssertNotNil(held)
        let git = StubGit()
        let engine = SyncEngine(gitService: git, manifestService: ManifestService(),
                                storeRebuildService: StoreRebuildService(), fileService: FileService(),
                                lockPath: lockPath)
        XCTAssertThrowsError(try engine.sync(root: tempDir, message: "m",
                                             credential: nil, context: makeContext())) {
            XCTAssertEqual($0 as? SyncError, .syncInProgress)
        }
        XCTAssertTrue(git.calls.isEmpty, "lock must short-circuit before git operations")
    }

    func testInspectConflictsShortCircuitsUnderPreHeldLock() throws {
        let held = SyncLock.tryAcquire(at: lockPath)
        defer { held?.release() }
        XCTAssertNotNil(held)
        let git = StubGit()
        let engine = SyncEngine(gitService: git, manifestService: ManifestService(),
                                storeRebuildService: StoreRebuildService(), fileService: FileService(),
                                lockPath: lockPath)
        XCTAssertThrowsError(try engine.inspectConflicts(root: tempDir, credential: nil,
                                                         context: makeContext())) {
            XCTAssertEqual($0 as? SyncError, .syncInProgress)
        }
        XCTAssertTrue(git.calls.isEmpty, "lock must short-circuit before git operations")
    }

    func testResolveConflictsShortCircuitsUnderPreHeldLock() throws {
        let held = SyncLock.tryAcquire(at: lockPath)
        defer { held?.release() }
        XCTAssertNotNil(held)
        let git = StubGit()
        let engine = SyncEngine(gitService: git, manifestService: ManifestService(),
                                storeRebuildService: StoreRebuildService(), fileService: FileService(),
                                lockPath: lockPath)
        XCTAssertThrowsError(try engine.resolveConflicts(root: tempDir, picks: [:],
                                                         credential: nil, context: makeContext())) {
            XCTAssertEqual($0 as? SyncError, .syncInProgress)
        }
        XCTAssertTrue(git.calls.isEmpty, "lock must short-circuit before git operations")
    }
}
