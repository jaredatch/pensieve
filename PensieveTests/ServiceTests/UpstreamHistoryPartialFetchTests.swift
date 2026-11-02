import XCTest
@testable import Pensieve

extension UpstreamHistoryServiceTests {
    private struct PartialHistoryFixture {
        let repository: String
        let commits: [String]
        let unrelatedObjects: [String]
        let fileCount: Int
    }

    private func partialHistoryFixture(rows: Int, files: Int = 2) throws -> PartialHistoryFixture {
        let repository = try makeRepository()
        try write("skills/demo/SKILL.md", text: "version 0\n", in: repository)
        for index in 1 ..< files {
            try write("skills/demo/file-\(index).txt", text: "file \(index)\n", in: repository)
        }
        _ = try commit(repository, message: "base")
        var commits: [String] = []
        var unrelated: [String] = []
        for version in 1 ... rows {
            try write("skills/demo/SKILL.md", text: "version \(version)\n", in: repository)
            try write("other/large.bin", data: Data((0 ..< 262_144).map { _ in UInt8.random(in: .min ... .max) }),
                      in: repository)
            commits.append(try commit(repository, message: "version \(version)", timestamp: 1_700_020_000 + version))
            unrelated.append(try revision("HEAD:other/large.bin", in: repository))
        }
        // Opt in explicitly here so these regression tests already exercise the desired server at the base.
        XCTAssertEqual(try rawGit(["-C", repository, "config", "uploadpack.allowFilter", "true"]).exit, 0)
        return PartialHistoryFixture(repository: repository, commits: commits,
                                     unrelatedObjects: unrelated, fileCount: files)
    }

    private func partialRequest(_ fixture: PartialHistoryFixture, scratch: String,
                                installedIndex: Int? = nil, commitLimit: Int? = nil,
                                rowLimit: Int = 20, remote: String? = nil,
                                credential: GitCredential? = nil) -> UpstreamHistoryGitRequest {
        UpstreamHistoryGitRequest(
            remote: remote ?? URL(fileURLWithPath: fixture.repository).absoluteString,
            ref: "main", installedCommit: fixture.commits[installedIndex ?? (fixture.commits.count - 1)],
            path: "skills/demo", repositoryPath: scratch, commitLimit: commitLimit ?? fixture.commits.count, rowLimit: rowLimit,
            textByteLimit: 256 * 1_024, baselineFileLimit: 512, baselineByteLimit: 8 * 1_024 * 1_024,
            credential: credential
        )
    }

    private func assertPartialRows(_ rows: [UpstreamHistoryGitRow], fixture: PartialHistoryFixture,
                                   count: Int? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let versions = Array((1 ... fixture.commits.count).reversed().prefix(count ?? fixture.commits.count))
        XCTAssertEqual(rows.map(\.sha), versions.map { fixture.commits[$0 - 1] }, file: file, line: line)
        XCTAssertEqual(rows.map(\.skillMarkdown), versions.map { .text("version \($0)\n") }, file: file, line: line)
        XCTAssertEqual(rows.map(\.filesChanged), versions.map { _ in 1 }, file: file, line: line)
        XCTAssertEqual(rows.map(\.linesAdded), versions.map { _ in 1 }, file: file, line: line)
        XCTAssertEqual(rows.map(\.linesRemoved), versions.map { _ in 1 }, file: file, line: line)
    }

    private func assertPartialBaseline(_ baseline: UpstreamHistoryBaseline?, fixture: PartialHistoryFixture,
                                       version: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let files = try XCTUnwrap(baseline?.files, file: file, line: line)
        var expected: [String: UpstreamHistoryFileContent] = ["SKILL.md": .text("version \(version)\n")]
        for index in 1 ..< fixture.fileCount { expected["file-\(index).txt"] = .text("file \(index)\n") }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.content) }), expected,
                       file: file, line: line)
    }

    private func assertUnrelatedObjectsAbsent(_ fixture: PartialHistoryFixture, scratch: String,
                                              file: StaticString = #filePath, line: UInt = #line) throws {
        for object in fixture.unrelatedObjects {
            let probe = try rawGit(["-C", scratch, "cat-file", "-e", object],
                                   environment: ["GIT_NO_LAZY_FETCH": "1"])
            XCTAssertNotEqual(probe.exit, 0, "downloaded unrelated blob \(object)", file: file, line: line)
        }
    }

    func testHistoryReadFetchesNoBlobOutsideTheSkillFolderAndStaysComplete() throws {
        try NativeTestWork.run { [self] in
            let fixture = try partialHistoryFixture(rows: 3)
            let scratch = tempDir + "/partial"
            let git = GitService(fileService: fileService, askpassHelperPath: tempDir + "/askpass")
            let result = try git.upstreamHistory(partialRequest(fixture, scratch: scratch))
            assertPartialRows(result.rows, fixture: fixture)
            guard case let .reachable(pathCommit) = result.installedPosition else {
                return XCTFail("installed commit must be reachable")
            }
            XCTAssertEqual(pathCommit, fixture.commits.last)
            try assertPartialBaseline(result.installedBaseline, fixture: fixture, version: 3)
            try assertUnrelatedObjectsAbsent(fixture, scratch: scratch)
        }
    }

    func testOlderInstalledCommitIsFetchedPartiallyWithACompleteBaseline() throws {
        try NativeTestWork.run { [self] in
            let fixture = try partialHistoryFixture(rows: 6, files: 4)
            let scratch = tempDir + "/older-partial"
            let git = GitService(fileService: fileService, askpassHelperPath: tempDir + "/askpass")
            let result = try git.upstreamHistory(partialRequest(fixture, scratch: scratch,
                                                               installedIndex: 0, commitLimit: 2))
            assertPartialRows(result.rows, fixture: fixture, count: 2)
            guard case .olderThanScan = result.installedPosition else { return XCTFail("outside shallow scan") }
            try assertPartialBaseline(result.installedBaseline, fixture: fixture, version: 1)
            try assertUnrelatedObjectsAbsent(fixture, scratch: scratch)
        }
    }

    func testGitProcessCountDoesNotGrowWithRowsOrInstalledFilesAndReadsStayComplete() throws {
        try NativeTestWork.run { [self] in
            let counter = try GitFailureFixture()
            defer { try? counter.remove() }
            let git = try counter.executable("exec /usr/bin/git \"$@\"")
            var counts: [Int] = []
            for (rows, files) in [(3, 2), (20, 40)] {
                let fixture = try partialHistoryFixture(rows: rows, files: files)
                try counter.files.writeFile(at: counter.trace, content: "")
                let result = try git.upstreamHistory(partialRequest(fixture, scratch: tempDir + "/count-\(rows)"))
                assertPartialRows(result.rows, fixture: fixture)
                try assertPartialBaseline(result.installedBaseline, fixture: fixture, version: rows)
                counts.append(try counter.files.readFile(at: counter.trace).split(separator: "\n").count)
                try fileService.deleteDirectory(at: fixture.repository)
            }
            XCTAssertEqual(counts[0], counts[1])
            XCTAssertLessThan(counts[0], 20)
            XCTAssertLessThan(counts[1], 20)
        }
    }

    func testHistoryBeyondTheVisibleRowsIsReportedWithoutReadingHiddenRowTexts() throws {
        try NativeTestWork.run { [self] in
            let fixture = try partialHistoryFixture(rows: 25)
            let recorder = try GitFailureFixture()
            defer { try? recorder.remove() }
            let inputTrace = recorder.base + "/batch-requests"
            try recorder.files.writeFile(at: inputTrace, content: "")
            let git = try recorder.executable("""
                case "$*" in
                  *--batch-check*) tee -a '\(inputTrace)' | /usr/bin/git "$@" ;;
                  *) exec /usr/bin/git "$@" ;;
                esac
                """)
            let result = try service(git: git, contentHasher: FixedContentHasher(value: "same")).read(
                origin: origin(repo: URL(fileURLWithPath: fixture.repository).absoluteString,
                               installedCommit: try XCTUnwrap(fixture.commits.last), contentHash: "same"),
                localDirectory: localDirectory
            )
            XCTAssertTrue(result.hasOlderHistory)
            let versions = Array((6 ... 25).reversed())
            XCTAssertEqual(result.rows.map(\.sha), versions.map { fixture.commits[$0 - 1] })
            XCTAssertEqual(result.rows.map(\.skillMarkdown), versions.map { .text("version \($0)\n") })
            let requests = try recorder.files.readFile(at: inputTrace).split(separator: "\n").map(String.init)
            XCTAssertEqual(requests, versions.map { fixture.commits[$0 - 1] + ":skills/demo/SKILL.md" })
        }
    }

    func testPartialReadAuthenticatesEveryNetworkCallWithTheInstallCredential() throws {
        try NativeTestWork.run { [self] in
            let fixture = try partialHistoryFixture(rows: 3)
            let authentication = try GitCredentialFixture(transport: .https)
            defer { try? authentication.remove() }
            _ = try authentication.raw(["-C", fixture.repository, "push", authentication.bare, "main"])
            _ = try authentication.raw(["-C", authentication.bare, "config", "uploadpack.allowFilter", "true"])
            try authentication.clearTraces()
            let scratch = tempDir + "/authenticated-partial"
            let result = try authentication.git.upstreamHistory(partialRequest(
                fixture, scratch: scratch, remote: authentication.remote, credential: authentication.credential
            ))
            assertPartialRows(result.rows, fixture: fixture)
            try assertPartialBaseline(result.installedBaseline, fixture: fixture, version: 3)
            XCTAssertEqual(try authentication.files.readFile(at: authentication.foreignTrace), "")
            try assertUnrelatedObjectsAbsent(fixture, scratch: scratch)
        }
    }
    func testDeclinedInstalledBlobPrefetchKeepsRowsAndLeavesBaselineUnavailable() throws {
        try NativeTestWork.run { [self] in
            let fixture = try partialHistoryFixture(rows: 6)
            let installedObject = try revision(fixture.commits[0] + ":skills/demo/SKILL.md", in: fixture.repository)
            let executor = GitService(fileService: fileService, askpassHelperPath: tempDir + "/askpass")
            var declined = false
            let git = GitService(fileService: fileService, askpassHelperPath: tempDir + "/askpass",
                                 upstreamHistoryNetworkRunner: { args, credential, inputPath in
                if let inputPath, try self.fileService.readFile(at: inputPath).contains(installedObject) {
                    declined = true
                    return GitService.GitOutput(stdout: "", stderr: "server declined installed blobs", exit: 128)
                }
                return try executor.run(args, in: nil, credential: credential, inputPath: inputPath,
                                        environment: GitService.historyEnvironment)
            })
            let result = try git.upstreamHistory(partialRequest(fixture, scratch: tempDir + "/declined-prefetch",
                                                               installedIndex: 0, commitLimit: 2))
            XCTAssertTrue(declined)
            assertPartialRows(result.rows, fixture: fixture, count: 2)
            guard case .olderThanScan = result.installedPosition else { return XCTFail("outside shallow scan") }
            XCTAssertNil(result.installedBaseline)
        }
    }

    func testHistoryCompletesWhenServerIgnoresBlobFilter() throws {
        try NativeTestWork.run { [self] in
            let fixture = try partialHistoryFixture(rows: 3)
            XCTAssertEqual(try rawGit(["-C", fixture.repository, "config", "uploadpack.allowFilter", "false"]).exit, 0)
            let git = GitService(fileService: fileService, askpassHelperPath: tempDir + "/askpass")
            let result = try git.upstreamHistory(partialRequest(fixture, scratch: tempDir + "/unfiltered-server"))
            assertPartialRows(result.rows, fixture: fixture)
            try assertPartialBaseline(result.installedBaseline, fixture: fixture, version: 3)
        }
    }

    func testMalformedBatchContentFailsTheReadInsteadOfLosingRecordBoundaries() throws {
        try NativeTestWork.run { [self] in
            let fixture = try partialHistoryFixture(rows: 1)
            let object = try revision("HEAD:skills/demo/SKILL.md", in: fixture.repository)
            let shim = try GitFailureFixture()
            defer { try? shim.remove() }
            let outputs = [
                object + " missing\n",
                "malformed header\n",
                object + " blob 1\nx\n",
                object + " blob 10\nshort",
                object + " blob 10\nversion 1\n\ntrailing"
            ]
            for (index, output) in outputs.enumerated() {
                let git = try shim.executable("""
                    case "$*" in
                      *' --batch') printf '%s' '\(output)' ;;
                      *) exec /usr/bin/git "$@" ;;
                    esac
                    """)
                XCTAssertThrowsError(try git.upstreamHistory(partialRequest(
                    fixture, scratch: tempDir + "/malformed-\(index)"
                ))) { XCTAssertTrue($0 is GitError) }
            }
        }
    }

}
