import XCTest
@testable import Pensieve

final class UnifiedDiffTests: XCTestCase {
    func testGeneratedShapesReplayExactlyWithNumbersAndHeaders() {
        let shapes = ["", "a", "a\n", "\n", "a\r\nb\r\n", "a\rb", "é\n", "e\u{301}\n", "a\nb\nc\n"]
        var pairs = shapes.flatMap { old in shapes.map { (old, $0) } }
        let baseline = (1...25).map { "line\($0)\n" }
        for first in baseline.indices {
            for last in first..<baseline.count {
                var changed = baseline
                changed[first] = "first\n"
                changed[last] = "last\n"
                pairs.append((baseline.joined(), changed.joined()))
            }
        }
        XCTAssertEqual(pairs.count, 406)
        for (old, new) in pairs {
            assertReplay(old: old, new: new)
        }
    }

    func testSixContextLinesMergeAndSevenSeparate() {
        for gap in 0...10 {
            let before = (0..<20).map { "line\($0)\n" }
            var after = before
            after[3] = "changed one\n"
            after[4 + gap] = "changed two\n"
            let diff = UnifiedDiff(old: before.joined(), new: after.joined())
            XCTAssertEqual(diff.hunks.count, gap <= 6 ? 1 : 2, "gap \(gap)")
            assertReplay(old: before.joined(), new: after.joined())
        }
    }

    func testLineCountsMatchRealGitNumstatForFixturePairs() throws {
        let root = NSTemporaryDirectory() + "UnifiedDiffOracle-\(UUID().uuidString)"
        let files = FileService()
        try files.createDirectory(at: root)
        defer { try? files.deleteDirectory(at: root) }
        let shapes = ["", "a", "a\n", "\n", "a\r\nb\r\n", "a\rb", "a\nb\na\n", "a\na\nb\n", "b\n"]
        for old in shapes {
            for new in shapes {
                try files.writeFile(at: root + "/old", content: old)
                try files.writeFile(at: root + "/new", content: new)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["--no-pager", "diff", "--numstat", "--no-index", "--no-ext-diff", "--no-textconv",
                                     "--", root + "/old", root + "/new"]
                process.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = Pipe()
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                XCTAssertTrue([0, 1].contains(process.terminationStatus))
                let fields = try XCTUnwrap(String(data: data, encoding: .utf8)).split(separator: "\t")
                let diff = UnifiedDiff(old: old, new: new)
                let expectedAdded = fields.isEmpty ? 0 : try XCTUnwrap(Int(fields[0]))
                let expectedRemoved = fields.isEmpty ? 0 : try XCTUnwrap(Int(fields[1]))
                let label = "old=\(old.debugDescription) new=\(new.debugDescription)"
                XCTAssertEqual(diff.linesAdded, expectedAdded, label)
                XCTAssertEqual(diff.linesRemoved, expectedRemoved, label)
            }
        }
    }

    func testLargeRealisticRewritesGetFullDiffsMatchingGitNumstat() throws {
        let old = (0..<2_500).map { "old \($0)\n" }.joined()
        let new = (0..<2_500).map { "new \($0)\n" }.joined()
        let baseline = (0..<2_000).map { "line \($0)\n" }
        var scattered = baseline
        for index in stride(from: 0, to: 2_000, by: 7) { scattered[index] = "changed \(index)\n" }
        let pairs = [(old, new), ("", String(repeating: "added\n", count: 300)),
                     (baseline.joined(), scattered.joined())]
        try assertFullDiffsMatchingGit(pairs)
    }

    func testLargeSparseEditsGetFullHunksMatchingGitNumstat() throws {
        var pairs: [(String, String)] = []
        for (count, indices) in [(5_000, [0, 4_999]),
                                 (209_715, (0..<10).map { $0 * 20_971 })] {
            let before = Array(repeating: "aaaa\n", count: count)
            var after = before
            for index in indices { after[index] = "bbbb\n" }
            let diff = UnifiedDiff(old: before.joined(), new: after.joined())
            XCTAssertFalse(diff.isTooLarge, "Sparse edits need full diffs at \(count) lines")
            XCTAssertEqual(diff.hunks.count, indices.count)
            XCTAssertEqual(diff.linesAdded, indices.count)
            XCTAssertEqual(diff.linesRemoved, indices.count)
            pairs.append((before.joined(), after.joined()))
        }
        try assertFullDiffsMatchingGit(pairs)
    }

    private func assertFullDiffsMatchingGit(_ pairs: [(String, String)]) throws {
        let root = NSTemporaryDirectory() + "LargeDiffOracle-\(UUID().uuidString)"
        let files = FileService()
        try files.createDirectory(at: root)
        defer { try? files.deleteDirectory(at: root) }
        for (old, new) in pairs {
            try files.writeFile(at: root + "/old", content: old)
            try files.writeFile(at: root + "/new", content: new)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["--no-pager", "diff", "--numstat", "--no-index", "--no-ext-diff", "--no-textconv",
                                 "--", root + "/old", root + "/new"]
            process.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 1)
            let fields = try XCTUnwrap(String(data: data, encoding: .utf8)).split(separator: "\t")
            let preview = PinnedSkillDiff(comparison: FileTreeComparison(changes: [FileTreeChange(
                path: "SKILL.md", kind: old.isEmpty ? .added : .modified, content: .text(old: old, new: new)
            )], unreadFileCount: 0, bytesRead: 0))
            let file = try XCTUnwrap(preview.files.first)
            XCTAssertNotEqual(file.content, .tooLarge, "Realistic rewrites must have full diffs")
            XCTAssertEqual(file.linesAdded, try XCTUnwrap(Int(fields[0])))
            XCTAssertEqual(file.linesRemoved, try XCTUnwrap(Int(fields[1])))
            assertReplay(old: old, new: new)
        }
    }

    private func assertReplay(old: String, new: String, file: StaticString = #filePath, line: UInt = #line) {
        let diff = UnifiedDiff(old: old, new: new)
        let oldLines = independentLines(old)
        let newLines = independentLines(new)
        var replay: [String] = []
        var cursor = 0
        var added = 0
        var removed = 0
        for hunk in diff.hunks {
            let start = hunk.oldCount == 0 ? hunk.oldStart : hunk.oldStart - 1
            XCTAssertGreaterThanOrEqual(start, cursor, file: file, line: line)
            replay.append(contentsOf: oldLines[cursor..<start])
            var oldNumber = start + 1
            var newNumber = (hunk.newCount == 0 ? hunk.newStart : hunk.newStart - 1) + 1
            XCTAssertEqual(replay.count + 1, newNumber, file: file, line: line)
            for row in hunk.lines {
                if row.kind != .added {
                    XCTAssertEqual(row.oldLineNumber, oldNumber, file: file, line: line)
                    XCTAssertEqual(Array(row.text.utf8), Array(oldLines[oldNumber - 1].utf8), file: file, line: line)
                    oldNumber += 1
                } else { XCTAssertNil(row.oldLineNumber, file: file, line: line); added += 1 }
                if row.kind != .removed {
                    XCTAssertEqual(row.newLineNumber, newNumber, file: file, line: line)
                    XCTAssertEqual(Array(row.text.utf8), Array(newLines[newNumber - 1].utf8), file: file, line: line)
                    replay.append(row.text)
                    newNumber += 1
                } else { XCTAssertNil(row.newLineNumber, file: file, line: line); removed += 1 }
            }
            XCTAssertEqual(oldNumber - (start + 1), hunk.oldCount, file: file, line: line)
            let newStart = hunk.newCount == 0 ? hunk.newStart : hunk.newStart - 1
            XCTAssertEqual(newNumber - (newStart + 1), hunk.newCount, file: file, line: line)
            let header = "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"
            XCTAssertEqual(hunk.header, header, file: file, line: line)
            cursor = start + hunk.oldCount
        }
        replay.append(contentsOf: oldLines[cursor...])
        XCTAssertEqual(Array(replay.joined().utf8), Array(new.utf8), file: file, line: line)
        XCTAssertEqual(added, diff.linesAdded, file: file, line: line)
        XCTAssertEqual(removed, diff.linesRemoved, file: file, line: line)
    }

    private func independentLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var result = text.components(separatedBy: "\n").map { $0 + "\n" }
        result.removeLast()
        if !text.hasSuffix("\n"), let last = text.components(separatedBy: "\n").last { result.append(last) }
        return result
    }
}
