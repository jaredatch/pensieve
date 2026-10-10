import XCTest
@testable import Pensieve

@MainActor
final class SkillHistoryTimelineTests: XCTestCase {
    func testRowsMarkTheNewestCurrentAndConnectTheDots() {
        let versions = makeVersions(count: 3)

        let rows = SkillHistoryTimeline.rows(versions, showAll: false)

        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows[0].isCurrent)
        XCTAssertFalse(rows[0].connectsUp)
        XCTAssertTrue(rows[0].connectsDown)
        XCTAssertFalse(rows[1].isCurrent)
        XCTAssertTrue(rows[1].connectsUp)
        XCTAssertTrue(rows[1].connectsDown)
        XCTAssertTrue(rows[2].connectsUp)
        XCTAssertFalse(rows[2].connectsDown)
    }

    func testTenRowsShowUntilOlderIsAsked() {
        let versions = makeVersions(count: 12)
        let firstPage = SkillHistoryTimeline.rows(versions, showAll: false)

        XCTAssertEqual(firstPage.count, 10)
        XCTAssertEqual(SkillHistoryTimeline.olderLabel(total: versions.count, shown: firstPage.count),
                       "Show older versions")

        let allRows = SkillHistoryTimeline.rows(versions, showAll: true)
        XCTAssertEqual(allRows.count, 12)
        XCTAssertNil(SkillHistoryTimeline.olderLabel(total: versions.count, shown: allRows.count))

        let shorterHistory = makeVersions(count: 4)
        let shorterRows = SkillHistoryTimeline.rows(shorterHistory, showAll: false)
        XCTAssertEqual(shorterRows.count, 4)
        XCTAssertNil(SkillHistoryTimeline.olderLabel(total: shorterHistory.count, shown: shorterRows.count))
    }

    func testMetaJoinsDateAndAuthor() throws {
        let version = SkillHistoryVersion(
            sha: "abc", date: try localDate(year: 2026, month: 8, day: 19, hour: 11, minute: 38),
            author: "Pensieve Sync", subject: "Update"
        )

        XCTAssertEqual(SkillHistoryTimeline.meta(for: version, locale: Locale(identifier: "en_US")),
                       "Aug 19, 2026 at 11:38\u{202F}AM · Pensieve Sync")
    }

    func testSnapshotReadsTheSkillFilePath() {
        let git = SkillHistoryRecordingGit()
        git.commits = [GitCommit(sha: "abc", author: "A", date: Date(), subject: "Update")]
        let skill = Skill(name: "Example", directoryName: "example-skill")

        let snapshot = SkillHistorySnapshot.load(path: SkillHistorySnapshot.path(for: skill), git: git, workingDir: "/repo")

        XCTAssertEqual(snapshot.versions.map(\.sha), ["abc"])
        XCTAssertEqual(git.logCalls, [.init(path: "skills/example-skill/SKILL.md", workingDir: "/repo", limit: 50)])
    }

    func testRestoreMessageNamesUnsavedChanges() throws {
        let version = SkillHistoryVersion(
            sha: "abc", date: try localDate(year: 2026, month: 8, day: 12, hour: 15, minute: 12),
            author: "Pensieve Sync", subject: "Update"
        )
        let base = "SKILL.md will be replaced with the version from Aug 12, 2026 at 3:12\u{202F}PM."

        XCTAssertEqual(SkillHistoryTab.restoreMessage(
            version: version, unsaved: false, locale: Locale(identifier: "en_US")
        ), base)
        XCTAssertEqual(SkillHistoryTab.restoreMessage(
            version: version, unsaved: true, locale: Locale(identifier: "en_US")
        ), base + " Your unsaved changes will be lost.")
    }

    func testAnEmptyLogIsAnEmptySnapshot() {
        let snapshot = SkillHistorySnapshot.load(
            path: "skills/example/SKILL.md",
            git: SkillHistoryRecordingGit(),
            workingDir: "/repo"
        )

        XCTAssertEqual(snapshot, SkillHistorySnapshot())
    }

    func testEverySyncTerminalChangesTheReloadKey() {
        let skillID = UUID()
        let syncing = SkillHistorySnapshot.ReloadKey(
            skillID: skillID, reloadToken: 2, appWriteRevision: 3, syncSignal: .syncing
        )
        let terminals: [SkillHistorySyncSignal] = [
            .synced(Date(timeIntervalSince1970: 4)),
            .conflicted(["skills/example/SKILL.md"]),
            .error("network unavailable"),
            .unconfigured
        ]

        for signal in terminals {
            XCTAssertNotEqual(syncing, SkillHistorySnapshot.ReloadKey(
                skillID: skillID, reloadToken: 2, appWriteRevision: 3, syncSignal: signal
            ))
        }
    }

    private func makeVersions(count: Int) -> [SkillHistoryVersion] {
        (0..<count).map { index in
            SkillHistoryVersion(sha: "sha-\(index)", date: Date(timeIntervalSince1970: TimeInterval(100 - index)),
                                author: "Author", subject: "Version \(index)")
        }
    }

    private func localDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return try XCTUnwrap(calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        )))
    }
}

final class SkillHistoryRecordingGit: GitServiceProtocol {
    struct LogCall: Equatable {
        let path: String
        let workingDir: String
        let limit: Int
    }

    var commits: [GitCommit] = []
    var documents: [String: String] = [:]
    private var recordedLogCalls: [LogCall] = []
    private let callLock = NSLock()
    var logOperation: ((String) -> [GitCommit])?
    var showOperation: ((String) -> String?)?
    var logCalls: [LogCall] {
        callLock.lock()
        defer { callLock.unlock() }
        return recordedLogCalls
    }

    func performLog(forPath path: String, at workingDir: String, limit: Int) -> [GitCommit] {
        callLock.lock()
        recordedLogCalls.append(LogCall(path: path, workingDir: workingDir, limit: limit))
        callLock.unlock()
        return logOperation?(path) ?? commits
    }

    func performShow(sha: String, path: String, at workingDir: String) -> String? {
        if let showOperation { return showOperation(sha) }
        return documents[sha]
    }
    func performRemoteURL(at path: String) -> String? { nil }
    func performInitRepository(at path: String) throws {}
    func performSetRemote(_ url: String, at path: String) throws {}
    func performRemoveRemote(at path: String) throws {}
    func performConfiguredRemoteURL(at path: String) throws -> String? { nil }
    func performClone(remote: String, into path: String, credential: GitCredential?) throws {}
    func performRemoteHasCommits(remote: String, credential: GitCredential?) -> Bool { false }
    @discardableResult func performStageAllAndCommit(at path: String, message: String) throws -> Bool { false }
    func performPreflightStoreUpdate(at path: String, credential: GitCredential?) -> FetchedStoreRevision? { nil }
    func performPullRebase(at path: String, fetchedRevision: FetchedStoreRevision) throws -> PullResult {
        try pullRebase(at: path, credential: nil)
    }
    func performPullRebase(at path: String, credential: GitCredential?) throws -> PullResult { .upToDate }
    func performPush(at path: String, credential: GitCredential?) throws {}
    func performAbortRebase(at path: String) throws {}
    func performConflictedFiles(at path: String) -> [String] { [] }
    func performBlob(atStage stage: Int, path: String, in workingDir: String) -> Data? { nil }
    func performContinueRebase(at path: String) throws -> PullResult { .upToDate }
    func performSkipRebase(at path: String) throws -> PullResult { .upToDate }
    func performStagePath(_ path: String, at root: String) throws {}
    func performCollapseToSingleCommit(at root: String, message: String, credential: GitCredential?,
                                       fetchedRevision: FetchedStoreRevision?) throws -> Bool { false }
    func performHasCommitsToPush(at path: String) -> Bool { false }
}
