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
    func isWorktreeClean(at path: String) -> Bool { false }
    func fastForwardOnly(at path: String, credential: GitCredential?) throws -> FastForwardResult { .diverged }
    func manifestMatchesHead(at path: String) throws -> Bool { false }
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

    func log(forPath path: String, at workingDir: String, limit: Int) -> [GitCommit] {
        callLock.lock()
        recordedLogCalls.append(LogCall(path: path, workingDir: workingDir, limit: limit))
        callLock.unlock()
        return logOperation?(path) ?? commits
    }

    func show(sha: String, path: String, at workingDir: String) -> String? {
        if let showOperation { return showOperation(sha) }
        return documents[sha]
    }
    func remoteURL(at path: String) -> String? { nil }
    func initRepository(at path: String) throws {}
    func setRemote(_ url: String, at path: String) throws {}
    func removeRemote(at path: String) throws {}
    func configuredRemoteURL(at path: String) throws -> String? { nil }
    func clone(remote: String, into path: String, credential: GitCredential?) throws {}
    func remoteHasCommits(remote: String, credential: GitCredential?) -> Bool { false }
    @discardableResult func stageAllAndCommit(at path: String, message: String) throws -> Bool { false }
    func preflightStoreUpdate(at path: String, credential: GitCredential?) -> FetchedStoreRevision? { nil }
    func pullRebase(at path: String, fetchedRevision: FetchedStoreRevision) throws -> PullResult {
        try pullRebase(at: path, credential: nil)
    }
    func pullRebase(at path: String, credential: GitCredential?) throws -> PullResult { .upToDate }
    func push(at path: String, credential: GitCredential?) throws {}
    func abortRebase(at path: String) throws {}
    func conflictedFiles(at path: String) -> [String] { [] }
    func blob(atStage stage: Int, path: String, in workingDir: String) -> Data? { nil }
    func continueRebase(at path: String) throws -> PullResult { .upToDate }
    func skipRebase(at path: String) throws -> PullResult { .upToDate }
    func stagePath(_ path: String, at root: String) throws {}
    func collapseToSingleCommit(at root: String, message: String, credential: GitCredential?,
                                fetchedRevision: FetchedStoreRevision?) throws -> Bool { false }
    func hasCommitsToPush(at path: String) -> Bool { false }

    func conflictEntry(atStage stage: Int, path: String, in workingDir: String) throws -> ConflictEntry? {

        try blob(atStage: stage, path: path, in: workingDir).map {

            ConflictEntry(mode: "100644", objectID: "", bytes: $0)

        }

    }

    func restoreConflictEntry(_ entry: ConflictEntry, stage: Int, path: String, at root: String) throws {

        throw GitError.repositoryUnreadable(path: root, detail: "Conflict entry restoration is unavailable.")

    }

    func removeConflictEntryFromIndex(_ path: String, at root: String) throws {

        throw GitError.repositoryUnreadable(path: root, detail: "Conflict index removal is unavailable.")

    }

    func retireConflictPath(_ path: String, at root: String) throws {

        throw GitError.repositoryUnreadable(path: root, detail: "Legacy gitlink resolution is unavailable.")

    }

    func probeUsability() -> GitUsability { .usable }

    func checkoutUnbornBranch(_ branch: String, at path: String) throws {}

    func fetchBranch(_ branch: String, at path: String, credential: GitCredential?) throws {}

    func materializeFromFetchHead(at path: String) throws {}

    func bornBranch(_ branch: String, at path: String) throws {}

    func setUpstream(branch: String, at path: String) throws {}

    func hasLocalBranches(at path: String) throws -> Bool { true }

    func hasRemoteTrackingBranch(_ branch: String, at path: String) -> Bool { false }

    func hasRemoteOriginConfigured(at path: String) throws -> Bool { true }

    func remoteReferences(remote: String, credential: GitCredential?) throws -> GitRemoteReferences {

        GitRemoteReferences(defaultBranch: nil, heads: [])

    }
}
