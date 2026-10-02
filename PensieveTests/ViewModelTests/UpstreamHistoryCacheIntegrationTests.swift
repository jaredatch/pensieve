import XCTest
@testable import Pensieve

@MainActor
final class UpstreamHistoryCacheIntegrationTests: UpstreamHistoryCacheTestCase {
    /// Protects 39.1-a: cache identity ignores timestamp precision lost by JSON's millisecond dates.
    func testSubmillisecondOriginDatesSurviveRelaunchWithoutFetch() async throws {
        let preciseDate = Date(timeIntervalSince1970: 1_700_000_000.123_499_6)
        let skill = installedHistorySkill(recordedHead: String(repeating: "b", count: 40))
        var preciseOrigin = try origin(for: skill)
        preciseOrigin.installedAt = preciseDate
        preciseOrigin.updatedAt = preciseDate
        skill.installedOrigin = preciseOrigin
        let expected = result()
        let first = owner(cache: cache(), read: { _, _, _ in expected })

        await first.request(skill: skill)

        var revendored = try origin(for: skill)
        revendored.updatedAt = preciseDate.addingTimeInterval(90)
        skill.installedOrigin = revendored

        let fetchProbe = LockedHistoryProbe()
        let relaunched = owner(cache: cache()) { _, _, _ in
            fetchProbe.recordCall()
            return self.result(head: String(repeating: "c", count: 40))
        }
        await relaunched.request(skill: skill)

        XCTAssertEqual(relaunched.state, .loaded(expected))
        XCTAssertEqual(fetchProbe.calls, 0)
    }

    /// Protects 39.2-k: a held disk load cannot publish its rows after the user selects another skill.
    func testSkillSwitchDuringDiskLoadNeverPublishesTheFirstSkillsRows() async throws {
        let first = installedHistorySkill(name: "First")
        let second = installedHistorySkill(name: "Second", commit: String(repeating: "c", count: 40))
        let firstResult = result(subject: "first")
        let secondResult = result(head: String(repeating: "d", count: 40), subject: "second")
        let disk = cache()
        try store(firstResult, for: first, in: disk)
        try store(secondResult, for: second, in: disk)
        let secondLoadStarted = DispatchSemaphore(value: 0)
        let releaseSecondLoad = TestWait.Gate(owner: self)
        let localProbe = LockedHistoryProbe()
        let model = historyOwner(
            read: { _, _, _ in XCTFail("disk entries should answer"); return firstResult },
            localEdits: { directory, _, _ in
                if directory.hasSuffix("/second") && localProbe.calls == 0 {
                    localProbe.recordCall()
                    secondLoadStarted.signal()
                    try releaseSecondLoad.wait()
                }
                return .none
            },
            localDirectory: { self.tempRoot + "/" + $0 },
            cache: cache()
        )

        await model.request(skill: first)
        XCTAssertEqual(model.state, .loaded(firstResult))
        let pendingSecond = Task { await model.request(skill: second) }
        let secondLoadDidStart = await waitForHistorySemaphore(secondLoadStarted)
        XCTAssertTrue(secondLoadDidStart)

        XCTAssertEqual(model.currentSkillID, second.id)
        XCTAssertEqual(model.state, .loading)
        releaseSecondLoad.open()
        await pendingSecond.value
        XCTAssertEqual(model.state, .loaded(secondResult))
    }

    func testRelaunchShowsDiskRowsWhileHeadProbeIsStillRunning() async throws {
        let kept = result()
        let skill = installedHistorySkill(recordedHead: kept.headCommit)
        let writer = cache()
        let generation = writer.beginRequest(skillID: skill.id, superseding: false)
        writer.store(
            skillID: skill.id,
            origin: try origin(for: skill),
            recordedHeadAtRead: skill.lastCheckedHead,
            result: kept,
            generation: generation,
            ordinal: 1
        )
        let probeStarted = DispatchSemaphore(value: 0)
        let releaseProbe = TestWait.Gate(owner: self)
        let fetchProbe = LockedHistoryProbe()
        let relaunched = owner(
            cache: cache(),
            read: { _, _, _ in fetchProbe.recordCall(); return kept },
            head: { _ in
                probeStarted.signal()
                try releaseProbe.wait()
                return kept.headCommit
            }
        )

        let request = Task { await relaunched.request(skill: skill) }
        let probeDidStart = await waitForHistorySemaphore(probeStarted)
        XCTAssertTrue(probeDidStart)
        XCTAssertEqual(relaunched.state, .loaded(kept))
        XCTAssertEqual(fetchProbe.calls, 0)

        releaseProbe.open()
        await request.value
        XCTAssertEqual(relaunched.state, .loaded(kept))
    }

    func testSuccessfulReadSurvivesRelaunchWithoutFetchAndOutsideStoreAndScratch() async throws {
        let skill = installedHistorySkill(recordedHead: String(repeating: "b", count: 40))
        let expected = result()
        let firstProbe = LockedHistoryProbe()
        let first = owner(cache: cache()) { _, _, _ in
            firstProbe.recordCall()
            return expected
        }

        await first.request(skill: skill)
        XCTAssertEqual(first.state, .loaded(expected))
        XCTAssertEqual(firstProbe.calls, 1)
        XCTAssertTrue(fileService.isRegularFile(at: cachePath(skill.id)))
        XCTAssertFalse(fileService.directoryExists(at: storeRoot + "/upstream-history-cache"))
        XCTAssertFalse(fileService.directoryExists(at: scratchRoot + "/upstream-history-cache"))

        try fileService.createDirectory(at: scratchRoot)
        try fileService.writeFile(at: scratchRoot + "/partial", content: "scratch")
        UpstreamHistoryService.cleanupScratchRoot(fileService: fileService, scratchRoot: scratchRoot)
        XCTAssertTrue(fileService.isRegularFile(at: cachePath(skill.id)))

        let secondProbe = LockedHistoryProbe()
        let second = owner(cache: cache()) { _, _, _ in
            secondProbe.recordCall()
            return self.result(head: String(repeating: "c", count: 40))
        }
        await second.request(skill: skill)

        XCTAssertEqual(second.state, .loaded(expected))
        XCTAssertEqual(secondProbe.calls, 0)
    }

    func testLoadRemeasuresAnEditMadeBetweenLaunchesAndLaterRevision() async throws {
        let skill = installedHistorySkill(recordedHead: String(repeating: "b", count: 40))
        let localDirectory = tempRoot + "/local-skill"
        try fileService.writeFile(at: localDirectory + "/SKILL.md", content: "before\n")
        let baseline = UpstreamHistoryBaseline.files([UpstreamHistoryBaselineFile(
            path: "SKILL.md",
            content: .text("before\n"),
            fingerprint: UpstreamHistoryService.gitBlobFingerprint(Data("before\n".utf8)),
            isExecutable: false
        )])
        let expected = result(baseline: baseline)
        let first = owner(cache: cache(), read: { _, _, _ in expected }, localDirectory: localDirectory)
        await first.request(skill: skill)

        try fileService.writeFile(at: localDirectory + "/SKILL.md", content: "after\n")
        let service = UpstreamHistoryService(
            fileService: fileService,
            contentHasher: FixedContentHasher(value: "sha256:changed"),
            scratchRoot: scratchRoot
        )
        let fetchProbe = LockedHistoryProbe()
        let second = owner(
            cache: cache(),
            read: { _, _, _ in fetchProbe.recordCall(); return expected },
            localEdits: { directory, hash, loadedBaseline in
                try service.localEdits(
                    localDirectory: directory,
                    installedContentHash: hash,
                    baseline: loadedBaseline
                )
            },
            localDirectory: localDirectory
        )

        await second.request(skill: skill)
        let changes = try loadedChanges(second.state)
        XCTAssertEqual(fetchProbe.calls, 0)
        XCTAssertEqual(changes.map(\.path), ["SKILL.md"])
        XCTAssertEqual(changes.first?.installedText, "before\n")
        XCTAssertEqual(changes.first?.currentText, "after\n")

        try fileService.writeFile(at: localDirectory + "/SKILL.md", content: "after again\n")
        await second.request(
            skill: skill,
            localRevision: UpstreamHistoryLocalRevision(appWriteRevision: 1, watcherEventSequence: 0)
        )
        let laterChanges = try loadedChanges(second.state)
        XCTAssertEqual(laterChanges.first?.currentText, "after again\n")
        XCTAssertEqual(fetchProbe.calls, 0)
    }

    func testUnreadableCacheDestinationNeverFailsTheNetworkRead() async throws {
        try fileService.writeFile(at: cacheDirectory, content: "not a directory")
        let skill = installedHistorySkill()
        let expected = result()
        let model = owner(cache: cache()) { _, _, _ in expected }

        await model.request(skill: skill)

        XCTAssertEqual(model.state, .loaded(expected))
        XCTAssertEqual(try fileService.readFile(at: cacheDirectory), "not a directory")
    }

    func testUnsafeDisplayFieldsAreSanitizedWhenLoaded() async throws {
        let skill = installedHistorySkill(recordedHead: String(repeating: "b", count: 40))
        let unsafeAuthor = "A\u{001B}[31muthor\u{202E}"
        let unsafeSubject = "Sub\u{0007}ject\u{202D}"
        let unsafeResult = result(rows: [row(author: unsafeAuthor, subject: unsafeSubject)])
        let disk = cache()
        let generation = disk.beginRequest(skillID: skill.id, superseding: false)
        disk.store(
            skillID: skill.id,
            origin: try origin(for: skill),
            recordedHeadAtRead: skill.lastCheckedHead,
            result: unsafeResult,
            generation: generation,
            ordinal: 1
        )
        let fetchProbe = LockedHistoryProbe()
        let model = owner(cache: cache()) { _, _, _ in
            fetchProbe.recordCall()
            return self.result()
        }

        await model.request(skill: skill)

        guard case let .loaded(loaded) = model.state else { return XCTFail("Expected cache hit") }
        XCTAssertEqual(loaded.rows.first?.author, UpstreamHistoryService.safeDisplay(unsafeAuthor, limit: 120))
        XCTAssertEqual(loaded.rows.first?.subject, UpstreamHistoryService.safeDisplay(unsafeSubject, limit: 300))
        XCTAssertEqual(fetchProbe.calls, 0)
    }
}

private extension UpstreamHistoryCacheIntegrationTests {
    func store(_ result: UpstreamHistoryResult, for skill: Skill, in cache: UpstreamHistoryCache) throws {
        let generation = cache.beginRequest(skillID: skill.id, superseding: false)
        cache.store(
            skillID: skill.id,
            origin: try origin(for: skill),
            recordedHeadAtRead: skill.lastCheckedHead,
            result: result,
            generation: generation,
            ordinal: 1
        )
    }

    func loadedChanges(_ state: UpstreamHistoryLoadState) throws -> [UpstreamHistoryLocalChange] {
        guard case let .loaded(result) = state,
              case let .changed(changes) = result.localEdits else {
            XCTFail("Expected local changes")
            throw CocoaError(.fileReadCorruptFile)
        }
        return changes
    }
}
