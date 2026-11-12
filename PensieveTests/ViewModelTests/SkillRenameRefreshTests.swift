import XCTest
@testable import Pensieve

@MainActor
final class SkillRenameRefreshTests: XCTestCase {
    func testRefreshKeepsTheRenamedRowsIdentityAndOwnDetails() async throws {
        for behindTagEdit in [false, true] {
            let gate = TestWait.Gate(owner: self)
            defer { gate.open() }
            let h = try SkillRenameTakeoverFixture(writeLockAttempted: { _ in
                guard !Thread.isMainThread else { return }
                do { try gate.wait() } catch { XCTFail("Publication gate failed: \(error)") }
            })
            defer { h.cleanup() }
            let id = h.skill.id
            if behindTagEdit {
                h.tagLibrary.updateMetadata(h.other, tags: ["edited"], scope: .user, context: h.context)
            }
            XCTAssertTrue(h.rename(), h.library.error ?? "")
            let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
            defer { held.release() }
            try h.moveHead()
            held.release()
            await TestWait.until(failureMessage: "The refreshed window never reached publication") { gate.waiterCount == 1 }
            try h.assertWindow()
            XCTAssertEqual(h.skill.id, id)
            gate.open()
            if behindTagEdit { gate.open() } // The tag edit and the rename each publish once.
            await h.saves.waitUntilIdle()
            XCTAssertNil(h.library.error)
            XCTAssertNil(h.tagLibrary.error)
            XCTAssertEqual(h.skill.id, id)
            try h.assertWindow()
            try h.assertOwn(h.manifest.read(fromRoot: h.root))
            if behindTagEdit {
                XCTAssertEqual(try h.manifest.read(fromRoot: h.root).skills.first { $0.slug == "other" }?.tags, ["edited"])
            }
        }
    }
}
