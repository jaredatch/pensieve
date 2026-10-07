import Darwin
import XCTest
@testable import Pensieve

extension FileTreeComparisonTests {
    func testAdmissionByteReceiptIsConsumedOnce() throws {
        try files.writeFile(at: new + "/text", content: "new\n")
        var calls = 0
        let comparison = try files.compareFileTrees(local: old, upstream: new, excludingUpstreamGit: true,
            limits: .updatePreview, beforeReading: { calls += 1; return 7 })
        XCTAssertEqual(calls, 1, "Admission byte accounting must consume one immutable receipt")
        XCTAssertEqual(comparison.bytesRead, 11)
    }

    func testPermissionReportUsesTheOpenedFilesAfterInventory() throws {
        for side in [old, new] {
            try files.writeFile(at: side + "/script", content: "same\n")
            XCTAssertEqual(chmod(side + "/script", 0o644), 0)
        }
        let comparison = try compare { event in
            if case let .directory(path) = event, path == self.new {
                XCTAssertEqual(chmod(self.old + "/script", 0o600), 0)
            }
        }
        let file = try XCTUnwrap(comparison.changes.first)
        XCTAssertEqual(file.permissions, .init(old: 0o600, new: 0o644),
                       "Reported permissions must come from the opened descriptors, even for an unstable file")
    }

    func testBinaryPermissionChangeKeepsContentAndModeInBothSummaries() throws {
        try files.writeData(at: old + "/binary", data: Data([0xff]))
        try files.writeData(at: new + "/binary", data: Data([0xfe]))
        XCTAssertEqual(chmod(old + "/binary", 0o644), 0)
        XCTAssertEqual(chmod(new + "/binary", 0o755), 0)
        let file = try XCTUnwrap(PinnedSkillDiff.build(comparison: try compare()).files.first)
        XCTAssertEqual(file.content, .binary)
        XCTAssertEqual(ViewChangesPresentation.sidebarMarker(file), "Binary file · Mode",
                       "The sidebar must show both binary content and its changed mode")
        XCTAssertEqual(ViewChangesPresentation.summary(file), "Binary file · Permissions changed from 0644 to 0755",
                       "The header must show permissions for binary content too")
        for (content, label) in [(FileTreeChange.Content.tooLarge, "Too large to show"),
                                 (.diffBudgetExhausted, "Preview diff budget exhausted"),
                                 (.diffOutputBoundReached, "Preview output bound reached")] {
            let unavailable = PinnedSkillFileDiff(change: FileTreeChange(path: "file", kind: .modified,
                content: content, permissions: file.permissions), result: nil)
            XCTAssertEqual(ViewChangesPresentation.sidebarMarker(unavailable), label + " · Mode")
            XCTAssertEqual(ViewChangesPresentation.summary(unavailable), label + " · Permissions changed from 0644 to 0755")
        }
    }

    func testBOMChangesMatchGitNumstatWithoutLosingBytes() throws {
        for (before, after) in [("first\n", "\u{FEFF}first\n"),
                                ("\u{FEFF}first\n", "first\n"),
                                ("first\nlast\n", "\u{FEFF}first\nchanged\n")] {
            try files.writeFile(at: old + "/text", content: before)
            try files.writeFile(at: new + "/text", content: after)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["--no-pager", "diff", "--numstat", "--no-index", "--no-ext-diff", "--no-textconv",
                                 "--", old + "/text", new + "/text"]
            process.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 1)
            let fields = try XCTUnwrap(String(data: data, encoding: .utf8)).split(separator: "\t")
            let preview = try PinnedSkillDiff.build(comparison: try compare())
            let file = try XCTUnwrap(preview.files.first)
            XCTAssertEqual(file.linesAdded, Int(fields[0]), "A leading BOM must count exactly as git counts it")
            XCTAssertEqual(file.linesRemoved, Int(fields[1]), "Removing a BOM must count exactly as git counts it")
            guard case let .text(oldText, newText) = file.content else { return XCTFail("Expected exact text") }
            XCTAssertEqual(Array(oldText.utf8), Array(before.utf8))
            XCTAssertEqual(Array(newText.utf8), Array(after.utf8))
        }
    }

    func testTextAndPermissionChangesBothReachWindowPresentation() throws {
        try files.writeFile(at: old + "/script", content: "old\n")
        try files.writeFile(at: new + "/script", content: "new\n")
        XCTAssertEqual(chmod(old + "/script", 0o644), 0)
        XCTAssertEqual(chmod(new + "/script", 0o755), 0)
        let file = try XCTUnwrap(PinnedSkillDiff.build(comparison: try compare()).files.first)
        XCTAssertEqual(file.linesAdded, 1)
        XCTAssertEqual(file.linesRemoved, 1)
        XCTAssertEqual(ViewChangesPresentation.sidebarMarker(file), "Mode", "The sidebar must mark the copied permission change")
        XCTAssertTrue(ViewChangesPresentation.summary(file).contains("Permissions changed from 0644 to 0755"),
                      "The file header must report copied permissions alongside text counts")
        XCTAssertTrue(ViewChangesPresentation.accessibilityLabel(file).contains("Permissions changed"))
    }

    func testAddedAndRemovedEmptyFilesHaveAnExplanation() throws {
        try files.writeData(at: new + "/added", data: Data())
        try files.writeData(at: old + "/removed", data: Data())
        let preview = try PinnedSkillDiff.build(comparison: try compare())
        XCTAssertEqual(preview.files.map { ViewChangesPresentation.unavailableReason($0) },
                       ["Empty file added", "Empty file removed"], "An empty file change must never show a blank diff")
        XCTAssertEqual(preview.files.map(\.linesAdded), [0, 0])
        XCTAssertEqual(preview.files.map(\.linesRemoved), [0, 0])
    }
}
