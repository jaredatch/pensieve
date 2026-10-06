import Darwin
import XCTest
@testable import Pensieve

extension FileTreeComparisonTests {
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
