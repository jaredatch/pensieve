import Darwin
import XCTest
@testable import Pensieve

extension UpstreamHistoryServiceTests {
    func testSymlinkInLocalCopyKeepsSuccessfulNetworkReadAsCountsUnknown() throws {
        try write("SKILL.md", text: "installed\n", in: localDirectory)
        let installedHash = try stableHash(at: localDirectory)
        try fileService.createSymlink(
            at: localDirectory + "/linked.txt",
            pointingTo: localDirectory + "/SKILL.md"
        )

        let result = try service(git: successfulBaselineGit()).read(
            origin: origin(
                repo: "fixture://remote",
                installedCommit: String(repeating: "a", count: 40),
                contentHash: installedHash
            ),
            localDirectory: localDirectory
        )

        XCTAssertEqual(result.localEdits, .countsUnknown)
        XCTAssertEqual(result.headCommit, String(repeating: "a", count: 40))
    }

    func testSpecialFileInLocalCopyKeepsSuccessfulNetworkReadAsCountsUnknown() throws {
        try write("SKILL.md", text: "installed\n", in: localDirectory)
        let installedHash = try stableHash(at: localDirectory)
        XCTAssertEqual(mkfifo(localDirectory + "/special", 0o644), 0)

        let result = try service(git: successfulBaselineGit()).read(
            origin: origin(
                repo: "fixture://remote",
                installedCommit: String(repeating: "a", count: 40),
                contentHash: installedHash
            ),
            localDirectory: localDirectory
        )

        XCTAssertEqual(result.localEdits, .countsUnknown)
        XCTAssertEqual(result.headCommit, String(repeating: "a", count: 40))
    }

    func testHeldBaselineKeepsRawPathsWhileLocalChangePathsAreDisplaySafe() throws {
        let rawPath = "unsafe\u{202e}.md"
        let baseline = UpstreamHistoryBaselineFile(
            path: rawPath,
            content: .text("before\n"),
            fingerprint: UpstreamHistoryService.gitBlobFingerprint(Data("before\n".utf8)),
            isExecutable: false
        )
        let git = RecordingUpstreamHistoryGit(result: .success(UpstreamHistoryGitSnapshot(
            headCommit: String(repeating: "a", count: 40),
            rows: [],
            installedPosition: .reachable(pathCommit: nil),
            hasMoreCommits: false,
            installedBaseline: .files([baseline])
        )))

        let result = try service(
            git: git,
            contentHasher: FixedContentHasher(value: "changed")
        ).read(
            origin: origin(
                repo: "fixture://remote",
                installedCommit: String(repeating: "a", count: 40),
                contentHash: "installed"
            ),
            localDirectory: localDirectory
        )

        XCTAssertEqual(result.installedBaseline?.files?.first?.path, rawPath)
        guard case let .changed(changes) = result.localEdits else {
            return XCTFail("expected the missing local file to be measured")
        }
        XCTAssertEqual(changes.first?.path, "unsafe.md")
    }

    func testSafeDisplayKeepsCharacterAfterBareEscapeAndRemovesBidiControls() {
        let unsafe = "a\u{1b}Zb\u{202e}c\u{2066}d\u{2069}"

        XCTAssertEqual(UpstreamHistoryService.safeDisplay(unsafe, limit: 100), "aZbcd")
    }

    private func successfulBaselineGit() -> RecordingUpstreamHistoryGit {
        let sha = String(repeating: "a", count: 40)
        let baseline = UpstreamHistoryBaselineFile(
            path: "SKILL.md",
            content: .text("installed\n"),
            fingerprint: UpstreamHistoryService.gitBlobFingerprint(Data("installed\n".utf8)),
            isExecutable: false
        )
        return RecordingUpstreamHistoryGit(result: .success(UpstreamHistoryGitSnapshot(
            headCommit: sha,
            rows: [],
            installedPosition: .reachable(pathCommit: nil),
            hasMoreCommits: false,
            installedBaseline: .files([baseline])
        )))
    }
}
