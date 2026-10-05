import XCTest
@testable import Pensieve

@MainActor
final class UpstreamHistoryCacheAdmissionTests: UpstreamHistoryCacheTestCase {
    func testVersionTwoBOMStrippedBaselineIsReadAgain() async throws {
        let skill = installedHistorySkill()
        let text = "\u{feff}a\n"
        let fingerprint = UpstreamHistoryService.gitBlobFingerprint(Data(text.utf8))
        let old = result(baseline: .files([UpstreamHistoryBaselineFile(
            path: "SKILL.md", content: .text("a\n"), fingerprint: fingerprint, isExecutable: false
        )]))
        try writeEnvelope(envelope(skill: skill, result: old, schemaVersion: 2), skillID: skill.id)
        let replacement = result(baseline: .files([UpstreamHistoryBaselineFile(
            path: "SKILL.md", content: .text(text), fingerprint: fingerprint, isExecutable: false
        )]))
        let probe = LockedHistoryProbe()
        let model = owner(cache: cache()) { _, _, _ in probe.recordCall(); return replacement }

        await model.request(skill: skill)

        XCTAssertEqual(probe.calls, 1)
        XCTAssertEqual(model.state, .loaded(replacement))
        let saved = try storedEnvelope(skill.id)
        XCTAssertEqual(saved.schemaVersion, UpstreamHistoryCache.schemaVersion)
        guard case let .text(savedText)? = saved.result.installedBaseline?.files?.first?.content else {
            return XCTFail("expected a freshly decoded baseline")
        }
        XCTAssertEqual(Data(savedText.utf8), Data(text.utf8))
    }

    /// Protects 39.1-c: the retired version-1 envelope is a clean miss after the schema bump.
    func testVersionOneEnvelopeIsACleanMiss() throws {
        let skill = installedHistorySkill()
        let old = try envelope(skill: skill, result: result(), schemaVersion: 1)
        try writeEnvelope(old, skillID: skill.id)
        let disk = cache()
        let generation = disk.beginRequest(skillID: skill.id, superseding: false)

        XCTAssertNil(disk.load(
            skillID: skill.id,
            origin: try origin(for: skill),
            minimumWindow: 1,
            generation: generation
        ))
    }

    func testTruncatedGarbageAndWrongSchemaFilesAreMissesAndGetReplaced() async throws {
        let skill = installedHistorySkill()
        let valid = try envelope(skill: skill, result: result())
        try writeEnvelope(valid, skillID: skill.id)
        let original = try fileService.readFile(at: cachePath(skill.id))
        let corruptions = [
            String(original.prefix(max(original.count / 2, 1))),
            "this is not json",
            try encoded(envelope(skill: skill, result: result(), schemaVersion: 99))
        ]

        for (index, corruption) in corruptions.enumerated() {
            try fileService.writeFile(at: cachePath(skill.id), content: corruption)
            let replacement = result(head: String(format: "%040x", index + 10))
            let probe = LockedHistoryProbe()
            let model = owner(cache: cache()) { _, _, _ in
                probe.recordCall()
                return replacement
            }

            await model.request(skill: skill)

            XCTAssertEqual(probe.calls, 1)
            XCTAssertEqual(model.state, .loaded(replacement))
            XCTAssertEqual(try storedEnvelope(skill.id).readHead, replacement.headCommit)
        }
    }

    func testEntryForDifferentOriginIsAMissAndGetsReplaced() async throws {
        let skill = installedHistorySkill()
        var other = try origin(for: skill)
        other.path = "skills/other"
        try writeEnvelope(
            envelope(skill: skill, result: result(subject: "must not show"), origin: other),
            skillID: skill.id
        )
        let replacement = result(head: String(repeating: "c", count: 40), subject: "replacement")
        let probe = LockedHistoryProbe()
        let model = owner(cache: cache()) { _, _, _ in probe.recordCall(); return replacement }

        await model.request(skill: skill)

        XCTAssertEqual(probe.calls, 1)
        XCTAssertEqual(model.state, .loaded(replacement))
        XCTAssertEqual(try storedEnvelope(skill.id).origin, try origin(for: skill))
    }

    func testMatchingButUnsafeStoredCoordinatesAreStillRejected() throws {
        let skill = installedHistorySkill()
        let validOrigin = try origin(for: skill)
        var invalidOrigins: [InstalledOrigin] = []
        var invalid = validOrigin
        invalid.repo = "file:///tmp/repository"
        invalidOrigins.append(invalid)
        invalid = validOrigin
        invalid.ref = "--upload-pack=payload"
        invalidOrigins.append(invalid)
        invalid = validOrigin
        invalid.path = "../outside"
        invalidOrigins.append(invalid)
        invalid = validOrigin
        invalid.installedCommit = "short"
        invalidOrigins.append(invalid)

        for invalidOrigin in invalidOrigins {
            try writeEnvelope(
                envelope(skill: skill, result: result(), origin: invalidOrigin),
                skillID: skill.id
            )
            let disk = cache()
            let generation = disk.beginRequest(skillID: skill.id, superseding: false)
            XCTAssertNil(disk.load(
                skillID: skill.id,
                origin: invalidOrigin,
                minimumWindow: 1,
                generation: generation
            ))
        }
    }

    /// Protects 39.1-i: every malformed decoded case below violates exactly one admission invariant.
    func testDecodedResultsBreakingEveryAdmissionInvariantAreMisses() async throws {
        let skill = installedHistorySkill()
        let invalidResults = try invalidDecodedResults(for: skill)

        for (index, invalid) in invalidResults.enumerated() {
            try writeEnvelope(envelope(skill: skill, result: invalid), skillID: skill.id)
            let replacement = result(head: String(format: "%040x", index + 100))
            let probe = LockedHistoryProbe()
            let model = owner(cache: cache()) { _, _, _ in probe.recordCall(); return replacement }

            await model.request(skill: skill)

            XCTAssertEqual(probe.calls, 1, "invalid case \(index)")
            XCTAssertEqual(model.state, .loaded(replacement), "invalid case \(index)")
        }
    }

    private func invalidDecodedResults(for skill: Skill) throws -> [UpstreamHistoryResult] {
        let validFingerprint = String(repeating: "d", count: 40)
        let duplicate = UpstreamHistoryBaseline.files([
            baselineFile(path: "SKILL.md", fingerprint: validFingerprint),
            baselineFile(path: "SKILL.md", fingerprint: validFingerprint)
        ])
        let tooManyRows = (0...UpstreamHistoryService.rowWindow).map {
            row(sha: String(format: "%040x", $0 + 1))
        }
        let tooManyFiles = UpstreamHistoryBaseline.files(
            (0...UpstreamHistoryService.baselineFileLimit).map {
                baselineFile(path: "file-\($0)", fingerprint: validFingerprint)
            }
        )
        let tooMuchText = String(repeating: "x", count: UpstreamHistoryService.textByteLimit + 1)
        let baselinePastByteLimit = UpstreamHistoryBaseline.files(
            (0..<33).map {
                baselineFile(
                    path: "large-\($0)",
                    content: .text(String(repeating: "x", count: UpstreamHistoryService.textByteLimit)),
                    fingerprint: validFingerprint
                )
            }
        )
        let badHead = String(repeating: "x", count: 40)
        let originCommit = try origin(for: skill).installedCommit
        let otherCommit = String(repeating: "c", count: 40)
        let zeroWindowOnly = result(
            window: 0,
            rows: [],
            position: .olderThanRowsRead
        )
        return [
            result(baseline: duplicate),
            zeroWindowOnly,
            result(rows: tooManyRows, position: .at(sha: tooManyRows[0].sha)),
            result(rows: [row(text: .text(tooMuchText))]),
            result(baseline: tooManyFiles),
            result(baseline: baselinePastByteLimit),
            result(head: badHead, rows: [row()], position: .at(sha: String(repeating: "b", count: 40))),
            result(rows: [row(sha: "short")], position: .olderThanRowsRead),
            result(position: .at(sha: otherCommit)),
            result(baseline: .files([baselineFile(path: "SKILL.md", fingerprint: "short")])),
            result(position: .notInRefHistory, baseline: .files([])),
            result(rows: [row(sha: originCommit)], position: .notInRefHistory, baseline: nil),
            result(rows: [row(sha: originCommit)], position: .olderThanRowsRead),
            result(
                rows: [row(sha: originCommit), row(sha: otherCommit)],
                position: .at(sha: otherCommit)
            )
        ]
    }

    func testHugeWindowMissCanThenLoadOlderAndMeasureLocallyWithoutTrap() async throws {
        let skill = installedHistorySkill()
        let huge = result(window: Int.max, position: .olderThanRowsRead)
        try writeEnvelope(envelope(skill: skill, result: huge), skillID: skill.id)
        let probe = LockedHistoryProbe()
        let model = owner(cache: cache()) { _, _, window in
            probe.recordCall()
            return self.result(window: window, position: .olderThanRowsRead)
        }

        await model.request(skill: skill)
        await model.request(
            skill: skill,
            windowCount: 2,
            localRevision: UpstreamHistoryLocalRevision(appWriteRevision: 1, watcherEventSequence: 0)
        )

        XCTAssertEqual(probe.calls, 2)
        guard case let .loaded(loaded) = model.state else { return XCTFail("Expected network result") }
        XCTAssertEqual(loaded.windowCount, 2)
    }

    /// Protects 39.1-i: the largest admitted window can advance once without arithmetic overflow.
    func testLargestAdmittedWindowCanShowOlderWithoutTrap() throws {
        let skill = installedHistorySkill()
        let largest = UpstreamHistoryCache.maximumAdmittedWindow
        let kept = result(window: largest, rows: [], position: .olderThanRowsRead)
        try writeEnvelope(envelope(skill: skill, result: kept), skillID: skill.id)
        let disk = cache()
        let generation = disk.beginRequest(skillID: skill.id, superseding: false)

        XCTAssertNotNil(disk.load(
            skillID: skill.id,
            origin: try origin(for: skill),
            minimumWindow: largest,
            generation: generation
        ))
        let session = InstalledSkillHistorySession()
        session.showOlder(.readNextWindow, currentWindow: largest)
        XCTAssertEqual(session.requestedWindow, largest + 1)
    }
}

private extension UpstreamHistoryCacheAdmissionTests {
    func encoded(_ envelope: UpstreamHistoryCache.Envelope) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try XCTUnwrap(String(data: encoder.encode(envelope), encoding: .utf8))
    }

    func baselineFile(
        path: String,
        content: UpstreamHistoryFileContent = .text("body"),
        fingerprint: String
    ) -> UpstreamHistoryBaselineFile {
        UpstreamHistoryBaselineFile(
            path: path,
            content: content,
            fingerprint: fingerprint,
            isExecutable: false
        )
    }
}
