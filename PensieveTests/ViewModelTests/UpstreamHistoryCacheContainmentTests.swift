import Darwin
import XCTest
@testable import Pensieve

final class UpstreamHistoryCacheContainmentTests: UpstreamHistoryCacheTestCase {
    func testSymlinkedCacheDirectoryIsNeverFollowedForReadWriteOrPrune() async throws {
        let skill = installedHistorySkill()
        let outside = tempRoot + "/outside"
        try fileService.createDirectory(at: outside)
        let fixture = outside + "/" + skill.id.uuidString.lowercased() + ".json"
        try fileService.writeFile(at: fixture, content: "outside bytes")
        try fileService.createSymlink(at: cacheDirectory, pointingTo: outside)
        let disk = cache()
        let generation = disk.beginRequest(skillID: skill.id, superseding: false)

        XCTAssertNil(disk.load(
            skillID: skill.id,
            origin: try origin(for: skill),
            minimumWindow: 1,
            generation: generation
        ))
        disk.store(
            skillID: skill.id,
            origin: try origin(for: skill),
            recordedHeadAtRead: nil,
            result: result(),
            generation: generation,
            ordinal: 1
        )
        disk.retain(skillIDs: [])

        XCTAssertEqual(try fileService.readFile(at: fixture), "outside bytes")
        XCTAssertTrue(fileService.isSymlink(at: cacheDirectory))
    }

    func testSymlinkedEntryIsNeverFollowedOrReplaced() async throws {
        let skill = installedHistorySkill()
        try fileService.createDirectory(at: cacheDirectory)
        let fixture = tempRoot + "/outside-entry.json"
        try fileService.writeFile(at: fixture, content: "outside bytes")
        try fileService.createSymlink(at: cachePath(skill.id), pointingTo: fixture)

        try await assertSpecialEntryIsUntouched(skill: skill)

        XCTAssertEqual(try fileService.readFile(at: fixture), "outside bytes")
        XCTAssertTrue(fileService.isSymlink(at: cachePath(skill.id)))
    }

    func testDirectoryEntryIsNeverOpenedReplacedOrPruned() async throws {
        let skill = installedHistorySkill()
        try fileService.createDirectory(at: cachePath(skill.id))
        let fixture = cachePath(skill.id) + "/fixture"
        try fileService.writeFile(at: fixture, content: "directory bytes")

        try await assertSpecialEntryIsUntouched(skill: skill)

        XCTAssertEqual(try fileService.readFile(at: fixture), "directory bytes")
        XCTAssertTrue(fileService.directoryExists(at: cachePath(skill.id)))
    }

    func testFIFOEntryReturnsWithoutBlockingAndIsNeverReplacedOrPruned() async throws {
        let skill = installedHistorySkill()
        try fileService.createDirectory(at: cacheDirectory)
        XCTAssertEqual(mkfifo(cachePath(skill.id), 0o600), 0)
        let completed = expectation(description: "FIFO was refused before open")

        Task.detached {
            let disk = self.cache()
            let generation = disk.beginRequest(skillID: skill.id, superseding: false)
            XCTAssertNil(disk.load(
                skillID: skill.id,
                origin: try self.origin(for: skill),
                minimumWindow: 1,
                generation: generation
            ))
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 1)
        try await assertSpecialEntryIsUntouched(skill: skill)

        XCTAssertNotNil(fileService.fileIdentity(at: cachePath(skill.id), followingLinks: false))
        XCTAssertFalse(fileService.isRegularFile(at: cachePath(skill.id)))
    }

    /// Protects 39.1-h and 39.1-k: stray special nodes consume no capacity they cannot release.
    func testSpecialEntriesCannotEvictAStoredRegularEntry() throws {
        let symlink = cachePath(UUID())
        let directory = cachePath(UUID())
        let fifo = cachePath(UUID())
        let target = tempRoot + "/outside-entry.json"
        try fileService.createDirectory(at: cacheDirectory)
        try fileService.writeFile(at: target, content: "outside bytes")
        try fileService.createSymlink(at: symlink, pointingTo: target)
        try fileService.createDirectory(at: directory)
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        let skill = installedHistorySkill()
        let disk = cache()
        let generation = disk.beginRequest(skillID: skill.id, superseding: false)

        disk.store(
            skillID: skill.id,
            origin: try origin(for: skill),
            recordedHeadAtRead: nil,
            result: result(),
            generation: generation,
            ordinal: 1
        )

        XCTAssertTrue(fileService.isRegularFile(at: cachePath(skill.id)))
        XCTAssertTrue(fileService.isSymlink(at: symlink))
        XCTAssertTrue(fileService.directoryExists(at: directory))
        XCTAssertNotNil(fileService.fileIdentity(at: fifo, followingLinks: false))
        XCTAssertEqual(try fileService.readFile(at: target), "outside bytes")
    }

    func testOversizedRegularEntryIsRejectedByBoundedRead() throws {
        let skill = installedHistorySkill()
        try fileService.writeFile(at: cachePath(skill.id), content: String(repeating: "x", count: 2_048))
        let disk = cache(entryLimit: 1_024)
        let generation = disk.beginRequest(skillID: skill.id, superseding: false)

        XCTAssertNil(disk.load(
            skillID: skill.id,
            origin: try origin(for: skill),
            minimumWindow: 1,
            generation: generation
        ))
    }
}

private extension UpstreamHistoryCacheContainmentTests {
    func assertSpecialEntryIsUntouched(skill: Skill) async throws {
        let disk = cache()
        let generation = disk.beginRequest(skillID: skill.id, superseding: false)
        XCTAssertNil(disk.load(
            skillID: skill.id,
            origin: try origin(for: skill),
            minimumWindow: 1,
            generation: generation
        ))
        disk.store(
            skillID: skill.id,
            origin: try origin(for: skill),
            recordedHeadAtRead: nil,
            result: result(),
            generation: generation,
            ordinal: 1
        )
        disk.retain(skillIDs: [])
    }
}
