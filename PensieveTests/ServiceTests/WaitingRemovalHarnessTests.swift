import XCTest
@testable import Pensieve

@MainActor
final class WaitingRemovalHarnessTests: XCTestCase {
    func testDeletedSkillSaveFinishesBeforeSandboxRemoval() async throws {
        let h = try WaitingRemovalHarness()
        let saves = try XCTUnwrap(h.library.manifestSaves)
        XCTAssertTrue(h.deleteSkill())
        var resolutions = 0
        // The deletion's synchronous file work is over; only its queued save can trip this.
        h.mapped.beforePathResolution = { _ in resolutions += 1 }
        XCTAssertGreaterThan(saves.pendingCount, 0)
        let finished = await h.tearDown(testName: name)
        XCTAssertTrue(finished)
        XCTAssertEqual(saves.pendingCount, 0)
        XCTAssertEqual(resolutions, 0)
        XCTAssertFalse(h.base.files.directoryExists(at: h.base.root))
        h.mapped.beforePathResolution = nil
        await saves.waitUntilIdle()
        h.base.cleanup()
    }

    func testTeardownClearsEveryHookOnBothDoubles() throws {
        let h = try WaitingRemovalHarness()
        do {
            defer { h.tearDown(after: self) }
            armAllHooks(h)
        }
        // Hooks must already be down before the async teardown block can get a turn.
        assertHooksCleared(h)
    }

    func testTeardownWaitsForQueueCreatedByTest() async throws {
        let h = try WaitingRemovalHarness()
        let saves = ManifestSaveModel(manifest: ManifestService(fileService: h.base.files),
            root: h.base.root + "/store", lockPath: h.base.root + "/store.sync.lock", files: h.mapped)
        let library = SkillLibraryViewModel(
            skillStore: SkillStore(fileService: h.mapped, baseDir: TestPaths.skillsDir, storeRoot: TestPaths.storeRoot),
            fileService: h.mapped, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir),
            manifestRoot: h.base.root + "/store", notifier: {}, manifestSaves: saves)
        h.trackSaveQueue(saves, named: "second library")
        XCTAssertTrue(SkillDeletionFlow.delete(skill: h.base.skill, library: library, platformVM: h.vm,
            projects: [h.base.project, h.base.otherProject], context: h.base.context))
        XCTAssertEqual(h.library.manifestSaves?.pendingCount, 0)
        XCTAssertGreaterThan(saves.pendingCount, 0)
        let finished = await h.tearDown(testName: name)
        XCTAssertTrue(finished)
        XCTAssertEqual(saves.pendingCount, 0)
        XCTAssertFalse(h.base.files.directoryExists(at: h.base.root))
        await saves.waitUntilIdle()
        h.base.cleanup()
    }

    func testUnfinishedSaveFailsItsOwnerAndPreservesSandboxWithHooksDown() async throws {
        let h = try WaitingRemovalHarness()
        let saves = try XCTUnwrap(h.library.manifestSaves)
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: saves.lockPath))
        defer { held.release() }
        XCTAssertTrue(h.deleteSkill())
        armAllHooks(h)
        XCTAssertGreaterThan(saves.pendingCount, 0)
        let ownerName = name
        let options = XCTExpectedFailure.Options()
        options.isStrict = true
        options.issueMatcher = {
            $0.compactDescription.contains("Unfinished manifest save: library.manifestSaves")
                && $0.compactDescription.contains(ownerName)
        }
        XCTExpectFailure("A blocked save must fail the test that owns it", options: options)
        let finished = await h.tearDown(testName: ownerName, timeout: .milliseconds(50)) // upper-bound: Deliberately held lock.
        XCTAssertFalse(finished)
        XCTAssertGreaterThan(saves.pendingCount, 0)
        assertHooksCleared(h)
        XCTAssertTrue(h.base.files.directoryExists(at: h.base.root))
        held.release()
        // The deliberately blocked worker must finish too, even if the assertions above fail.
        await saves.waitUntilIdle()
        XCTAssertEqual(saves.pendingCount, 0)
        h.base.cleanup()
    }

    private let hookPaths: [ReferenceWritableKeyPath<LinkServiceCanonicalDirectoryFileService,
        ((String) throws -> Void)?>] = [
        \.beforeDirectoryCreation, \.beforeArtifactCreation, \.beforeArtifactDeletion, \.beforeProjectProbe,
        \.beforeRuleRead, \.beforeEntryTypeProbe, \.beforeDeployStateRead, \.beforeDeployStateWrite,
        \.beforeFileWrite, \.beforeSymlinkRead, \.beforePathResolution
    ]

    private func armAllHooks(_ h: WaitingRemovalHarness) {
        for double in [h.mapped, h.base.mapped] {
            for path in hookPaths { double[keyPath: path] = { _ in XCTFail("A teardown hook outlived its test") } }
        }
    }

    private func assertHooksCleared(_ h: WaitingRemovalHarness, file: StaticString = #filePath, line: UInt = #line) {
        for double in [h.mapped, h.base.mapped] {
            for path in hookPaths { XCTAssertNil(double[keyPath: path], "\(path)", file: file, line: line) }
        }
    }
}
