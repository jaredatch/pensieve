import XCTest
@testable import Pensieve

@MainActor
extension UpstreamHistoryCacheLifecycleTests {
    /// Protects 39.1-g: cache lifecycle behavior has no test-only production drain seam.
    func testCacheHasNoTestOnlyDrainSeam() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try FileService().readFile(
            at: root.appendingPathComponent("Pensieve/Services/UpstreamHistoryCache.swift").path
        )

        XCTAssertFalse(source.contains("func drain()"))
    }

    /// Protects 39.1-g and 39.1-j: a queued removal wins over a later load of the same skill.
    func testQueuedRemovalCannotServeTheRemovedEntryToALaterGeneration() async throws {
        let blocking = BlockingDeleteHistoryFileService(base: fileService, owner: self)
        let disk = cache(fileService: blocking)
        let skill = installedHistorySkill(name: "Removed")
        let initial = disk.beginRequest(skillID: skill.id, superseding: false)
        disk.store(
            skillID: skill.id,
            origin: try origin(for: skill),
            recordedHeadAtRead: nil,
            result: result(subject: "removed"),
            generation: initial,
            ordinal: 1
        )
        let installedOrigin = try origin(for: skill)
        blocking.blockNextDelete(at: cachePath(skill.id))
        disk.remove(skillID: skill.id)
        let removalDidStart = await waitForHistorySemaphore(blocking.deleteStarted)
        XCTAssertTrue(removalDidStart)
        let later = disk.beginRequest(skillID: skill.id, superseding: false)

        let load = Task.detached {
            disk.load(
                skillID: skill.id,
                origin: installedOrigin,
                minimumWindow: 1,
                generation: later
            )
        }
        blocking.releaseDelete.open()

        let loaded = await load.value
        XCTAssertNil(loaded)
    }

    /// Protects 39.1-g and 39.1-j: a queued removal never deletes a later generation's stored entry.
    func testQueuedRemovalCannotDeleteALaterGenerationStore() async throws {
        let blocking = BlockingDeleteHistoryFileService(base: fileService, owner: self)
        let disk = cache(fileService: blocking)
        let skill = installedHistorySkill(name: "Restored")
        let initial = disk.beginRequest(skillID: skill.id, superseding: false)
        disk.store(
            skillID: skill.id,
            origin: try origin(for: skill),
            recordedHeadAtRead: nil,
            result: result(subject: "removed"),
            generation: initial,
            ordinal: 1
        )
        let installedOrigin = try origin(for: skill)
        blocking.blockNextDelete(at: cachePath(skill.id))
        disk.remove(skillID: skill.id)
        let removalDidStart = await waitForHistorySemaphore(blocking.deleteStarted)
        XCTAssertTrue(removalDidStart)
        let later = disk.beginRequest(skillID: skill.id, superseding: false)
        let fresh = result(head: String(repeating: "c", count: 40), subject: "fresh")

        let store = Task.detached {
            disk.store(
                skillID: skill.id,
                origin: installedOrigin,
                recordedHeadAtRead: nil,
                result: fresh,
                generation: later,
                ordinal: 2
            )
        }
        blocking.releaseDelete.open()
        await store.value

        let generation = disk.beginRequest(skillID: skill.id, superseding: false)
        XCTAssertEqual(disk.load(
            skillID: skill.id,
            origin: try origin(for: skill),
            minimumWindow: 1,
            generation: generation
        )?.readHead, fresh.headCommit)
    }
}
