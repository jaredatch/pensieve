import XCTest
@testable import Pensieve

extension SyncBytePreservationTests {
    func testIncomingTrackedExcludedFilesPauseBeforeAppWritesAndResumeAfterMovingThem() throws {
        for hidden in [false, true] {
            for path in ExcludedFileCollisionFixture.paths {
                do {
                    try assertIncomingExcludedCollision(path: path, hidden: hidden)
                } catch {
                    XCTFail("\(path), skill ignores=\(hidden): \(error)")
                }
            }
        }
    }

    private func assertIncomingExcludedCollision(path: String, hidden: Bool) throws {
        let fixture = try ExcludedFileCollisionFixture(path: path, hidden: hidden, localCommit: true)
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        let engine = SyncEngine(gitService: AllowlistedRemoteGit(wrapping: fixture.git),
                                lockPath: fixture.root + "/sync.lock")
        var prepared = false
        XCTAssertThrowsError(try engine.sync(root: fixture.storeB, message: "collision", credential: nil,
            context: fixture.context, prepare: { _ in prepared = true })) { error in
            XCTAssertEqual(error.localizedDescription, fixture.message)
        }
        XCTAssertFalse(prepared, "An incoming collision must stop before app snapshot preparation")
        try fixture.assertUntouched()
        // Direct rebase callers must also protect the same excluded bytes.
        XCTAssertThrowsError(try fixture.git.pullRebase(at: fixture.storeB, credential: nil)) { error in
            XCTAssertEqual(error.localizedDescription, fixture.message)
        }
        try fixture.assertUntouched()
        try fixture.moveLocalFile()
        guard case .synced = try engine.sync(root: fixture.storeB, message: "resume", credential: nil,
            context: fixture.context) else { return XCTFail("Moving the obstacle must allow sync") }
        try fixture.assertResumed()
    }
}
