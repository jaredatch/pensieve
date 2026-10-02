import XCTest
@testable import Pensieve

final class UpstreamHistoryCacheCapacityTests: UpstreamHistoryCacheTestCase {
    func testDefaultEntryCapFitsAWindowOneResultAtServiceLimits() {
        let maximumRawPayload = UpstreamHistoryService.rowWindow * UpstreamHistoryService.textByteLimit
            + UpstreamHistoryService.baselineByteLimit
        XCTAssertGreaterThanOrEqual(
            UpstreamHistoryCache.defaultEntryByteLimit,
            maximumRawPayload * 6
        )
    }

    func testEntryOverPerEntryCapIsNotKept() throws {
        let skill = installedHistorySkill()
        let disk = cache(entryLimit: 1)
        let generation = disk.beginRequest(skillID: skill.id, superseding: false)

        disk.store(
            skillID: skill.id,
            origin: try origin(for: skill),
            recordedHeadAtRead: nil,
            result: result(),
            generation: generation,
            ordinal: 1
        )

        XCTAssertFalse(fileService.fileExists(at: cachePath(skill.id)))
    }

    func testTotalCapEvictsLeastRecentlyUsedEntry() throws {
        let first = installedHistorySkill(name: "First")
        let second = installedHistorySkill(name: "Second")
        let third = installedHistorySkill(name: "Third")
        let sample = try envelope(skill: first, result: result(subject: String(repeating: "a", count: 300)))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let entrySize = try encoder.encode(sample).count
        let disk = cache(totalLimit: entrySize * 2 + 64)

        try store(first, in: disk, ordinal: 1)
        try store(second, in: disk, ordinal: 2)
        try fileService.touchRegularFile(
            at: cachePath(first.id),
            date: Date(timeIntervalSince1970: 1_700_000_001)
        )
        try fileService.touchRegularFile(
            at: cachePath(second.id),
            date: Date(timeIntervalSince1970: 1_700_000_002)
        )
        let firstGeneration = disk.beginRequest(skillID: first.id, superseding: false)
        XCTAssertNotNil(disk.load(
            skillID: first.id,
            origin: try origin(for: first),
            minimumWindow: 1,
            generation: firstGeneration
        ))
        try store(third, in: disk, ordinal: 3)

        XCTAssertTrue(fileService.isRegularFile(at: cachePath(first.id)))
        XCTAssertFalse(fileService.fileExists(at: cachePath(second.id)))
        XCTAssertTrue(fileService.isRegularFile(at: cachePath(third.id)))
    }

    /// Protects 39.1-a and 39.1-h: hits decode once, and pruning uses metadata instead of payload reads.
    func testHitsDecodeOnceAndPruningDoesNotReadOtherPayloads() throws {
        let first = installedHistorySkill(name: "First")
        let second = installedHistorySkill(name: "Second")
        let spy = CountingHistoryFileService(base: fileService)
        let disk = cache(fileService: spy)
        try store(first, in: disk, ordinal: 1)
        spy.resetRegularReads()
        let generation = disk.beginRequest(skillID: first.id, superseding: false)

        XCTAssertNotNil(disk.load(
            skillID: first.id,
            origin: try origin(for: first),
            minimumWindow: 1,
            generation: generation
        ))
        XCTAssertEqual(spy.regularReads, 1)

        spy.resetRegularReads()
        try store(second, in: disk, ordinal: 2)
        XCTAssertEqual(spy.regularReads, 1)
    }

    /// Protects 39.1-h: unknown metadata cannot make a cache entry disappear from capacity accounting.
    func testUnknownMetadataEntryIsEvictedInsteadOfExcludedFromTheTotal() throws {
        let skill = installedHistorySkill()
        let unknown = UnknownMetadataHistoryFileService(base: fileService)
        let disk = cache(totalLimit: 1, fileService: unknown)

        try store(skill, in: disk, ordinal: 1)

        XCTAssertFalse(fileService.fileExists(at: cachePath(skill.id)))
    }

    /// Protects 39.1-h: unknown metadata counts conservatively but does not force under-cap eviction.
    func testUnknownMetadataEntrySurvivesWhileTheCacheIsUnderTheTotalCap() throws {
        let skill = installedHistorySkill()
        let unknown = UnknownMetadataHistoryFileService(base: fileService)
        let disk = cache(fileService: unknown)

        try store(skill, in: disk, ordinal: 1)

        XCTAssertTrue(fileService.isRegularFile(at: cachePath(skill.id)))
    }

    /// Protects 39.1-h: an injected cache clock dates the published entry as well as later hits.
    func testInjectedClockDatesNewlyPublishedEntry() throws {
        let publishedAt = Date(timeIntervalSince1970: 1_700_000_123)
        let skill = installedHistorySkill()

        try store(skill, in: cache(now: { publishedAt }), ordinal: 1)

        XCTAssertEqual(
            fileService.regularFileMetadata(at: cachePath(skill.id))?.modificationDate,
            publishedAt
        )
    }

    /// Protects 39.1-h: a default-clock publication uses the atomic rename's timestamp without a touch.
    func testDefaultClockUsesRenamePublicationDateWithoutTouch() throws {
        let skill = installedHistorySkill()
        let recording = RecordingTouchHistoryFileService(base: fileService)
        let before = Date()

        try store(skill, in: cache(fileService: recording), ordinal: 1)

        let publishedAt = try XCTUnwrap(
            recording.regularFileMetadata(at: cachePath(skill.id))?.modificationDate
        )
        XCTAssertTrue(recording.touchDates.isEmpty)
        XCTAssertGreaterThanOrEqual(publishedAt, before.addingTimeInterval(-1))
        XCTAssertLessThanOrEqual(publishedAt, Date().addingTimeInterval(1))
    }

    /// Known regular-file metadata is the one capacity stat for an entry.
    func testCapacityRecordDoesNotRestatAnEntryWithKnownMetadata() throws {
        let skill = installedHistorySkill()
        let disk = cache()
        try store(skill, in: disk, ordinal: 1)
        let counting = MetadataCountingHistoryFileService(base: fileService)
        let inspected = cache(fileService: counting)

        XCTAssertNotNil(inspected.capacityRecord(path: cachePath(skill.id)))
        XCTAssertEqual(counting.metadataCalls, 1)
        XCTAssertEqual(counting.regularFileCalls, 0)
    }

    /// Protects 39.1-h and 39.1-k: pruning removes only stale regular cache temps, never active ones.
    func testStoreSweepsRegularOrphanedTemporaryFiles() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stale = cacheDirectory + "/." + UUID().uuidString + ".tmp"
        let active = cacheDirectory + "/." + UUID().uuidString + ".tmp"
        let target = cacheDirectory + "/target"
        let linkedOrphan = cacheDirectory + "/." + UUID().uuidString + ".tmp"
        try fileService.writeFile(at: stale, content: "stale")
        try fileService.writeFile(at: active, content: "active")
        try fileService.touchRegularFile(
            at: stale,
            date: now.addingTimeInterval(-UpstreamHistoryCache.staleTemporaryAge - 1)
        )
        try fileService.touchRegularFile(at: active, date: now)
        try fileService.writeFile(at: target, content: "keep")
        try fileService.createSymlink(at: linkedOrphan, pointingTo: target)
        let skill = installedHistorySkill()

        try store(skill, in: cache(now: { now }), ordinal: 1)

        XCTAssertFalse(fileService.fileExists(at: stale))
        XCTAssertTrue(fileService.isRegularFile(at: active))
        XCTAssertTrue(fileService.isSymlink(at: linkedOrphan))
        XCTAssertEqual(try fileService.readFile(at: target), "keep")
    }
}

private extension UpstreamHistoryCacheCapacityTests {
    func store(_ skill: Skill, in cache: UpstreamHistoryCache, ordinal: UInt64) throws {
        let generation = cache.beginRequest(skillID: skill.id, superseding: false)
        cache.store(
            skillID: skill.id,
            origin: try origin(for: skill),
            recordedHeadAtRead: nil,
            result: result(subject: String(repeating: "a", count: 300)),
            generation: generation,
            ordinal: ordinal
        )
    }
}
