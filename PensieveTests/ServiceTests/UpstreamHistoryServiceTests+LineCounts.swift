import XCTest
@testable import Pensieve

extension UpstreamHistoryServiceTests {
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
        _ installed: String?, _ current: String?, context: String,
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
        let actual = try XCTUnwrap(
            service().lineCounts(installed: installed.map { .text($0) }, current: current.map { .text($0) }),
            context, file: file, line: line
        )
        let message = "\(context): git diff --no-index --numstat reports +\(expected[0]) -\(expected[1]); "
            + "History reports +\(actual.added) -\(actual.removed)"
        XCTAssertEqual([actual.added, actual.removed], expected, message, file: file, line: line)
    }
}
