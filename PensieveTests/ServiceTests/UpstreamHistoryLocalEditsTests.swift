import XCTest
@testable import Pensieve

extension UpstreamHistoryServiceTests {
    func testIdenticalLocalCopyHasNoEditsAndAgreesWithStableDriftCheck() throws {
        try write("SKILL.md", text: "one\ntwo\n", in: localDirectory)
        try write("notes.txt", text: "note\n", in: localDirectory)
        let installedHash = try stableHash(at: localDirectory)
        let baseline = [
            UpstreamHistoryBaselineFile(
                path: "SKILL.md",
                content: .text("one\ntwo\n"),
                fingerprint: fingerprint("one\ntwo\n"),
                isExecutable: false
            ),
            UpstreamHistoryBaselineFile(
                path: "notes.txt",
                content: .text("note\n"),
                fingerprint: fingerprint("note\n"),
                isExecutable: false
            )
        ]
        let git = RecordingUpstreamHistoryGit(result: .success(snapshot(baseline: baseline)))

        let result = try service(git: git).read(
            origin: origin(
                repo: "fixture://remote",
                installedCommit: String(repeating: "a", count: 40),
                contentHash: installedHash
            ),
            localDirectory: localDirectory
        )

        XCTAssertEqual(result.localEdits, .none)
        XCTAssertFalse(UpdateCheckService.driftedLocally(
            currentContentHash: try stableHash(at: localDirectory),
            installedContentHash: installedHash
        ))
    }

    func testLocalEditsMeasureTextAndListBinaryAndOversizedFilesWithoutCounts() throws {
        let fixture = try makeEditedFixture()
        let git = RecordingUpstreamHistoryGit(result: .success(snapshot(baseline: fixture.baseline)))

        let result = try service(git: git).read(
            origin: origin(
                repo: "fixture://remote",
                installedCommit: String(repeating: "a", count: 40),
                contentHash: fixture.installedHash
            ),
            localDirectory: localDirectory
        )

        guard case let .changed(changes) = result.localEdits else {
            return XCTFail("expected measured local edits")
        }
        let byPath = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0) })
        XCTAssertEqual(byPath["SKILL.md"]?.linesAdded, 1)
        XCTAssertEqual(byPath["SKILL.md"]?.linesRemoved, 1)
        XCTAssertEqual(byPath["edit.txt"]?.linesAdded, 1)
        XCTAssertEqual(byPath["edit.txt"]?.linesRemoved, 1)
        XCTAssertEqual(byPath["added.txt"]?.linesAdded, 2)
        XCTAssertEqual(byPath["added.txt"]?.linesRemoved, 0)
        XCTAssertEqual(byPath["delete.txt"]?.linesAdded, 0)
        XCTAssertEqual(byPath["delete.txt"]?.linesRemoved, 1)
        XCTAssertNotNil(byPath["binary.dat"])
        XCTAssertNil(byPath["binary.dat"]?.linesAdded)
        XCTAssertNotNil(byPath["large.txt"])
        XCTAssertNil(byPath["large.txt"]?.linesAdded)
        XCTAssertTrue(UpdateCheckService.driftedLocally(
            currentContentHash: try stableHash(at: localDirectory),
            installedContentHash: fixture.installedHash
        ))
    }

    func testDriftWithoutBaselineIsExplicitlyCountsUnknown() throws {
        try write("SKILL.md", text: "locally edited\n", in: localDirectory)
        let git = RecordingUpstreamHistoryGit(result: .success(UpstreamHistoryGitSnapshot(
            headCommit: String(repeating: "c", count: 40),
            rows: [],
            installedPosition: .notInRefHistory,
            hasMoreCommits: false,
            installedBaseline: nil
        )))

        let result = try service(git: git).read(
            origin: origin(
                repo: "fixture://remote",
                installedCommit: String(repeating: "a", count: 40),
                contentHash: "sha256:not-the-current-copy"
            ),
            localDirectory: localDirectory
        )

        XCTAssertEqual(result.localEdits, .countsUnknown)
        XCTAssertTrue(UpdateCheckService.driftedLocally(
            currentContentHash: try stableHash(at: localDirectory),
            installedContentHash: "sha256:not-the-current-copy"
        ))
    }

    func testBodyOnlySaveReportsNoFrontmatterLinesAsLocalEdits() throws {
        let original = """
        ---
        name: Installed
        description: Upstream description
        license: Apache-2.0
        allowed-tools:
          - Read
        metadata:
          owner: upstream
        ---

        Old body
        """ + "\n"
        try write("SKILL.md", text: original, in: localDirectory)
        let installedHash = try stableHash(at: localDirectory)
        let parsed = SkillParser.parse(original)
        let store = SkillStore(fileService: fileService, baseDir: tempDir)
        try store.rewriteSkill(
            directoryName: "local",
            body: "Edited body",
            preserving: parsed,
            fallbackName: "Ignored",
            fallbackDescription: "Ignored"
        )

        let baseline = [UpstreamHistoryBaselineFile(
            path: "SKILL.md",
            content: .text(original),
            fingerprint: fingerprint(original),
            isExecutable: false
        )]
        let result = try service(git: RecordingUpstreamHistoryGit(result: .success(snapshot(baseline: baseline)))).read(
            origin: origin(
                repo: "fixture://remote",
                installedCommit: String(repeating: "a", count: 40),
                contentHash: installedHash
            ),
            localDirectory: localDirectory
        )
        guard case let .changed(changes) = result.localEdits else {
            return XCTFail("expected body edit")
        }
        let skillChange = try XCTUnwrap(changes.first { $0.path == "SKILL.md" })
        XCTAssertEqual(skillChange.linesAdded, 1)
        XCTAssertEqual(skillChange.linesRemoved, 1)
        let installedText = try XCTUnwrap(skillChange.installedText)
        let currentText = try XCTUnwrap(skillChange.currentText)
        XCTAssertEqual(
            SkillParser.parse(currentText).preservedFrontmatter?.source,
            SkillParser.parse(installedText).preservedFrontmatter?.source
        )
    }

    private func snapshot(
        baseline: [UpstreamHistoryBaselineFile]
    ) -> UpstreamHistoryGitSnapshot {
        let sha = String(repeating: "a", count: 40)
        return UpstreamHistoryGitSnapshot(
            headCommit: sha,
            rows: [],
            installedPosition: .reachable(pathCommit: nil),
            hasMoreCommits: false,
            installedBaseline: .files(baseline)
        )
    }

    private func fingerprint(_ text: String) -> String {
        UpstreamHistoryService.gitBlobFingerprint(Data(text.utf8))
    }

    private func makeEditedFixture() throws
        -> (installedHash: String, baseline: [UpstreamHistoryBaselineFile]) {
        let largeBefore = String(repeating: "a", count: UpstreamHistoryService.textByteLimit + 1)
        try write("SKILL.md", text: "one\ntwo\n", in: localDirectory)
        try write("edit.txt", text: "old\n", in: localDirectory)
        try write("delete.txt", text: "gone\n", in: localDirectory)
        try write("binary.dat", data: Data([0, 1]), in: localDirectory)
        try write("large.txt", text: largeBefore, in: localDirectory)
        let installedHash = try stableHash(at: localDirectory)
        let baseline = [
            baselineFile("SKILL.md", .text("one\ntwo\n"), fingerprint("one\ntwo\n")),
            baselineFile("edit.txt", .text("old\n"), fingerprint("old\n")),
            baselineFile("delete.txt", .text("gone\n"), fingerprint("gone\n")),
            baselineFile(
                "binary.dat",
                .binary,
                UpstreamHistoryService.gitBlobFingerprint(Data([0, 1]))
            ),
            baselineFile("large.txt", .tooLarge, fingerprint(largeBefore))
        ]
        try write("SKILL.md", text: "one\nchanged\n", in: localDirectory)
        try write("edit.txt", text: "new\n", in: localDirectory)
        try fileService.deleteFile(at: localDirectory + "/delete.txt")
        try write("added.txt", text: "new\nline\n", in: localDirectory)
        try fileService.deleteFile(at: localDirectory + "/binary.dat")
        try write("binary.dat", data: Data([0, 2]), in: localDirectory)
        let largeAfter = String(repeating: "b", count: UpstreamHistoryService.textByteLimit + 1)
        try write("large.txt", text: largeAfter, in: localDirectory)
        return (installedHash, baseline)
    }

    private func baselineFile(_ path: String, _ content: UpstreamHistoryFileContent,
                              _ fingerprint: String) -> UpstreamHistoryBaselineFile {
        UpstreamHistoryBaselineFile(
            path: path,
            content: content,
            fingerprint: fingerprint,
            isExecutable: false
        )
    }
}
