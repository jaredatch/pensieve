import XCTest
@testable import Pensieve

extension UpstreamHistoryServiceTests {
    func testLocalLineCountsMatchGitWhenBOMIsAdded() throws {
        try assertLineCountsMatchGit("a\n", "\u{feff}a\n", context: "BOM added", decodeFiles: true)
    }

    func testLocalLineCountsMatchGitWhenBOMIsRemoved() throws {
        try assertLineCountsMatchGit("\u{feff}a\n", "a\n", context: "BOM removed", decodeFiles: true)
    }

    func testHistoryDecodersKeepEveryUTF8ByteIncludingBOM() throws {
        let cases = ["\u{feff}a\r\ncafe\u{0301}\n", "\u{feff}", "\u{feff}\u{feff}a\n"]
        for source in cases {
            let bytes = Data(source.utf8)
            for (decoder, content) in [
                ("local", service().localContent(bytes)), ("historical", try decodedHistoricalContent(bytes))
            ] {
                let context = "\(decoder): source UTF-8 \(Array(bytes))"
                guard case let .text(text) = content else {
                    XCTFail("\(context): expected UTF-8 text")
                    continue
                }
                XCTAssertEqual(Array(text.utf8.prefix(3)), [0xef, 0xbb, 0xbf], context)
                XCTAssertEqual(Array(text.utf8), Array(bytes), context)
                XCTAssertEqual(
                    LineDiffView.alignedRows(this: "a\r\ncafe\u{0301}\n", other: text).first?.changed, true, context
                )
                let encoded = try JSONEncoder().encode(content)
                let decoded = try JSONDecoder().decode(UpstreamHistoryFileContent.self, from: encoded)
                guard case let .text(cachedText) = decoded else {
                    XCTFail("\(context): expected cached UTF-8 text")
                    continue
                }
                XCTAssertEqual(Array(cachedText.utf8), Array(bytes), "\(context): cached text")
            }
        }
    }

    func testHistoryDecodersKeepBinaryAndSizeAdmissionRules() throws {
        let cases: [(Data, UpstreamHistoryFileContent)] = [
            (Data(), .text("")),
            (Data("plain\r\n".utf8), .text("plain\r\n")),
            (Data([0xff]), .binary),
            (Data([0xef, 0xbb, 0xbf, 0xff]), .binary),
            (Data([0xc0, 0xaf]), .binary),
            (Data([0xe2, 0x82]), .binary),
            (Data([0xed, 0xa0, 0x80]), .binary),
            (Data([0xef, 0xbb, 0xbf, 0x61, 0, 0x0a]), .binary),
            (Data(repeating: 0, count: UpstreamHistoryService.textByteLimit + 1), .tooLarge),
            (Data(repeating: 0x61, count: UpstreamHistoryService.textByteLimit + 1), .tooLarge)
        ]
        for (bytes, expected) in cases {
            XCTAssertEqual(service().localContent(bytes), expected)
            XCTAssertEqual(try decodedHistoricalContent(bytes), expected)
        }
        let atLimit = "\u{feff}" + String(repeating: "a", count: UpstreamHistoryService.textByteLimit - 3)
        XCTAssertEqual(service().localContent(Data(atLimit.utf8)), .text(atLimit))
        XCTAssertEqual(try decodedHistoricalContent(Data(atLimit.utf8)), .text(atLimit))
    }

    @MainActor
    func testRestoreWritesDecodedHistoryBOMBytesExactly() throws {
        let bytes = Data("\u{feff}---\r\nname: Example\r\ndescription: Test\r\n---\r\nBody\r\n".utf8)
        let content = try decodedHistoricalContent(bytes)
        guard case let .text(document) = content else { return XCTFail("expected UTF-8 text") }
        let store = SkillStore(fileService: fileService, baseDir: tempDir + "/restored")
        let skill = Skill(name: "Example", directoryName: "example")
        try restoreSkillHistoryVersion(skill: skill, body: document, store: store, library: nil, notifier: {})
        XCTAssertEqual(try store.readData(directoryName: skill.directoryName), bytes)
    }

    func testLocalLineCountsMatchGitWhenFinalNewlineIsAdded() throws {
        try assertLineCountsMatchGit("last", "last\n", context: "final newline added")
        try assertLineCountsMatchGit(
            "changed\nthree", "one\ntwo\nthree\n", context: "final newline added with edits"
        )
    }

    func testLocalLineCountsMatchGitWhenFinalNewlineIsRemoved() throws {
        try assertLineCountsMatchGit("last\n", "last", context: "final newline removed")
        try assertLineCountsMatchGit(
            "one\ntwo\nthree\n", "changed\nthree", context: "final newline removed with edits"
        )
    }

    func testLocalLineCountsMatchGitForEditedUnterminatedLastLine() throws {
        try assertLineCountsMatchGit(
            "first\nold last", "first\nnew last", context: "edited unterminated last line"
        )
    }

    func testLocalLineCountsMatchGitForCRLF() throws {
        try assertLineCountsMatchGit(
            "first\r\nold\r\nlast\r\n", "first\r\nnew\r\nlast\r\n", context: "CRLF edit"
        )
        try assertLineCountsMatchGit("first\r\nlast\r\n", "first\nlast\n", context: "CRLF to LF")
        try assertLineCountsMatchGit("first\r\nlast", "first\r\nlast\r\n", context: "CRLF final newline")
    }

    func testLocalLineCountsMatchGitForNonLFSeparatorsInsideLine() throws {
        for separator in ["\r", "\u{2028}", "\u{2029}", "\u{0085}", "\u{000b}", "\u{000c}"] {
            try assertLineCountsMatchGit(
                "one\(separator)two\(separator)three\n",
                "changed\n",
                context: "non-LF separator \(separator.debugDescription)"
            )
            try assertLineCountsMatchGit(nil, "one\(separator)two", context: "added non-LF line")
        }
    }

    func testLocalLineCountsMatchGitForByteDifferentCanonicalEquivalents() throws {
        try assertLineCountsMatchGit(
            "caf\u{00e9}\n", "cafe\u{0301}\n", context: "canonical equivalents with different UTF-8 bytes"
        )
        try assertLineCountsMatchGit(
            "same\ncaf\u{00e9}", "same\ncafe\u{0301}", context: "unterminated canonical equivalents"
        )
    }

    func testLocalLineCountsMatchGitForEmptyFilesAndBlankLines() throws {
        try assertLineCountsMatchGit("", "", context: "both empty")
        try assertLineCountsMatchGit("", "one\n", context: "empty to terminated line")
        try assertLineCountsMatchGit("", "one", context: "empty to unterminated line")
        try assertLineCountsMatchGit("one\n", "", context: "line to empty")
        try assertLineCountsMatchGit("first\nlast\n", "first\n\nlast\n", context: "blank-line insertion")
        try assertLineCountsMatchGit("", "\n", context: "empty to blank line")
    }

    func testLocalLineCountsMatchGitForAddedAndDeletedFiles() throws {
        for text in ["", "one", "one\n", "one\n\nthree\n", "one\r\ntwo\r\n"] {
            try assertLineCountsMatchGit(nil, text, context: "whole file added \(text.debugDescription)")
            try assertLineCountsMatchGit(text, nil, context: "whole file deleted \(text.debugDescription)")
        }
        try assertLineCountsMatchGit(nil, nil, context: "both absent")
    }

    func testLocalLineCountsMatchGitForLargerMixedEditWithMoves() throws {
        let before = (1...48).map { "line \($0)\n" }
        var after = Array(before[0..<8])
        after += Array(before[24..<32])
        after += ["inserted one\n", "\n", "inserted two\n"]
        after += Array(before[8..<16])
        after += ["edited line 17\n"]
        after += Array(before[18..<24])
        after += Array(before[36..<47])
        after += ["line 48"]
        try assertLineCountsMatchGit(before.joined(), after.joined(), context: "48-line mixed edit with moves")
    }

    func testLocalLineCountsKeepBinaryAndOversizedCountsUnknown() {
        let history = service()
        for content in [UpstreamHistoryFileContent.binary, .tooLarge] {
            XCTAssertNil(history.lineCounts(installed: content, current: .text("one\n")))
            XCTAssertNil(history.lineCounts(installed: .text("one\n"), current: content))
            XCTAssertNil(history.lineCounts(installed: nil, current: content))
            XCTAssertNil(history.lineCounts(installed: content, current: nil))
        }
    }

    private func assertLineCountsMatchGit(
        _ installed: String?, _ current: String?, context: String, decodeFiles: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let beforeURL = URL(fileURLWithPath: tempDir + "/numstat-installed.txt")
        let afterURL = URL(fileURLWithPath: tempDir + "/numstat-current.txt")
        try Data((installed ?? "").utf8).write(to: beforeURL)
        try Data((current ?? "").utf8).write(to: afterURL)
        let git = try rawGit([
            "-C", tempDir, "diff", "--no-index", "--numstat", "--", beforeURL.path, afterURL.path
        ], environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
        guard git.exit == 0 || git.exit == 1 else {
            return XCTFail("git numstat exited \(git.exit): \(git.stderr)", file: file, line: line)
        }
        let expected: [Int]
        if git.exit == 0 && git.stdout.isEmpty {
            expected = [0, 0]
        } else {
            let columns = git.stdout.split(separator: "\t")
            guard columns.count >= 3 else { return XCTFail("invalid numstat: \(git.stdout)", file: file, line: line) }
            expected = try [
                XCTUnwrap(Int(columns[0]), git.stdout, file: file, line: line),
                XCTUnwrap(Int(columns[1]), git.stdout, file: file, line: line)
            ]
        }
        let before: UpstreamHistoryFileContent? = decodeFiles
            ? try decodedHistoricalContent(Data((installed ?? "").utf8)) : installed.map { .text($0) }
        let after: UpstreamHistoryFileContent? = decodeFiles
            ? service().localContent(Data((current ?? "").utf8)) : current.map { .text($0) }
        let actual = try XCTUnwrap(service().lineCounts(installed: before, current: after), context, file: file, line: line)
        let message = "\(context): git diff --no-index --numstat reports +\(expected[0]) -\(expected[1]); "
            + "History reports +\(actual.added) -\(actual.removed)"
        XCTAssertEqual([actual.added, actual.removed], expected, message, file: file, line: line)
    }

    private func decodedHistoricalContent(_ bytes: Data) throws -> UpstreamHistoryFileContent {
        let repository = try makeRepository()
        let url = URL(fileURLWithPath: tempDir + "/decoded-history.txt")
        try bytes.write(to: url)
        let result = try rawGit(["-C", repository, "hash-object", "--no-filters", "-w", "--", url.path])
        XCTAssertEqual(result.exit, 0, result.stderr)
        return try GitService(fileService: fileService,
            askpassHelperPath: TestPaths.gitAskpassHelperPath).historicalContent(
            object: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            size: bytes.count, repositoryPath: repository, textByteLimit: UpstreamHistoryService.textByteLimit
        )
    }
}
