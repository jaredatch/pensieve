import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class SkillRenameAbsorbTests: XCTestCase {
    func testRenameTakesOnlyItsOwnRecordsAndRollsBackCleanupOnFailure() async throws {
        for record in [true, false] {
            for wholeRowWrite in [false, true] {
                let h = try SkillRenameTakeoverFixture(record: record)
                defer { h.cleanup() }
                let id = h.skill.id
                XCTAssertTrue(h.rename(), h.library.error ?? "")
                let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
                defer { held.release() }
                try h.assertWindow()
                if wholeRowWrite {
                    let snapshot = try StoreIngestState.snapshotForPublication(using: h.manifest,
                        context: h.context, root: h.root)
                    try h.manifest.write(snapshot, toRoot: h.root)
                }
                held.release()
                await h.saves.waitUntilIdle()
                XCTAssertNil(h.library.error)
                XCTAssertEqual(h.skill.id, id)
                try h.assertOwn(h.manifest.read(fromRoot: h.root))
                try h.assertWindow()
                try h.assertFreshRebuild()
            }
        }
        let h = try SkillRenameTakeoverFixture()
        defer { h.cleanup() }
        let before = try h.manifest.snapshot(from: h.context)
        XCTAssertFalse(h.rename(persist: { _ in throw CocoaError(.fileWriteUnknown) }))
        XCTAssertTrue(h.files.directoryExists(at: h.store.baseDir + "/alpha"))
        XCTAssertFalse(h.files.directoryExists(at: h.store.baseDir + "/zulu"))
        let restored = try h.manifest.snapshot(from: h.context)
        XCTAssertEqual(restored.categories.sorted { $0.name < $1.name }, before.categories.sorted { $0.name < $1.name })
        XCTAssertEqual(restored.deployIntents.sorted { $0.machineID + $0.skillSlug < $1.machineID + $1.skillSlug },
            before.deployIntents.sorted { $0.machineID + $0.skillSlug < $1.machineID + $1.skillSlug })
        XCTAssertEqual(h.saves.pendingCount, 0)
    }
}
