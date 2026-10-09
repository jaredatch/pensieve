import XCTest
@testable import Pensieve

final class GitStageTwoRegressionTests: XCTestCase {
    func testSingleLinePreservesJoiners() {
        let text = "👩‍💻 می\u{200C}روم क्\u{200D}ष"
        XCTAssertEqual(DisplayTextSanitizer.singleLine(text), text)
    }

    func testSingleLineParsesEscapesBeforeJoiningLines() {
        for newline in ["\n", "\r\n", "\u{2028}", "\u{2029}"] {
            XCTAssertEqual(DisplayTextSanitizer.singleLine("bad\u{1B}" + newline + "repo"), "bad repo")
        }
        XCTAssertEqual(DisplayTextSanitizer.singleLine("one\n\ntwo"), "one two")
    }

    func testRootDisappearingDuringEntryLookupIsUnknown() throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let files = VanishingRootFiles(root: fixture.root)
        let git = GitService(fileService: files, askpassHelperPath: TestPaths.gitAskpassHelperPath)
        XCTAssertThrowsError(try git.remoteURL(at: fixture.root)) { error in
            guard case GitError.repositoryUnreadable = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(files.reads, ["entry", "directory"])
    }

    func testLogPreservesWhitespaceAndRemovesTerminalCommands() {
        let result = DaemonCLI.renderLog(
            current: "  \tbefore\u{1B}]0;window title\u{7}after  \n",
            rotated: "\t\u{1B}[31mred\u{1B}[0m\u{7}\u{0}\u{7F}\t\n", lines: 20
        )
        XCTAssertEqual(result.output, "\tred\t\n  \tbeforeafter  \n")
    }

    func testMalformedCSIAndInvisibleFormattingKeepPrintableLogContent() {
        XCTAssertEqual(DisplayTextSanitizer.logLine(" \t\u{1B}[日本語 failed \t"), " \t日本語 failed \t")
        XCTAssertEqual(DisplayTextSanitizer.logLine("a\u{202E}b\u{2028}c\u{2029}d"), "ab c d")
        XCTAssertEqual(DisplayTextSanitizer.logLine("a\u{1B}[31\tb"), "a\tb")
    }

    func testLogPreservesJoinersAndSeparatesUnicodeLines() {
        let text = "👩‍💻 می\u{200C}روم क्\u{200D}ष"
        XCTAssertEqual(DisplayTextSanitizer.logLine(text), text)
        let bidi = "\u{200E}\u{200F}\u{061C}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}"
            + "\u{2066}\u{2067}\u{2068}\u{2069}"
        XCTAssertEqual(DisplayTextSanitizer.logLine(" \t" + bidi + "text\u{2028}line\u{2029}end \t"),
                       " \ttext line end \t")
    }

    @MainActor
    func testSharedSanitizerBoundsMalformedCSIInConfigurationErrors() async throws {
        let text = "\u{1B}[日本語 failed"
        XCTAssertEqual(DisplayTextSanitizer.sanitize(text), "日本語 failed")
        XCTAssertEqual(DisplayTextSanitizer.singleLine(text), "日本語 failed")
        let git = IngestRecordingGit()
        git.remoteRead = { throw GitError.repositoryUnreadable(path: "/unused-test-root", detail: text) }
        let model = SyncModel(git: git, root: "/unused-test-root")
        let modelConfiguration = try RuntimeConfigurationFixture(model, defaults: isolatedDefaults("configuration"))
        defer { try? modelConfiguration.remove() }
        await modelConfiguration.refresh()
        XCTAssertTrue(model.configurationDescription.contains("日本語 failed"))
    }

    func testLogStripsInvisibleFormatsExceptJoiners() {
        let formats = "\u{200B}\u{2060}\u{2061}\u{2062}\u{2063}\u{2064}\u{206A}\u{206F}\u{E0001}\u{E0061}\u{E007F}"
        let printable = " \t👩‍💻 می\u{200C}روم क्\u{200D}ष  \t"
        XCTAssertEqual(DisplayTextSanitizer.logLine(formats + printable + formats), printable)
    }

    @MainActor
    func testAllDisplayEntryPointsRemoveTerminalStringPayloads() async throws {
        let commands = ["\u{1B}]8;;https://hidden.test\u{7}", "\u{1B}Psecret\u{1B}\\",
                        "\u{1B}^secret\u{1B}\\", "\u{1B}_secret\u{1B}\\", "\u{9B}31m",
                        "\u{9D}hidden\u{9C}", "\u{90}hidden\u{9C}", "\u{9E}hidden\u{9C}", "\u{9F}hidden\u{9C}"]
        for (index, command) in commands.enumerated() {
            let text = "before" + command + "after"
            XCTAssertEqual(DisplayTextSanitizer.sanitize(text), "beforeafter")
            XCTAssertEqual(DisplayTextSanitizer.singleLine(text), "beforeafter")
            XCTAssertEqual(DisplayTextSanitizer.logLine(text), "beforeafter")
            let git = IngestRecordingGit()
            git.remoteRead = { throw GitError.repositoryUnreadable(path: "fixture", detail: text) }
            let model = SyncModel(git: git, root: "/unused-test-root")
            let modelConfiguration = try RuntimeConfigurationFixture(model, defaults: isolatedDefaults("configuration-\(index)"))
            defer { try? modelConfiguration.remove() }
            await modelConfiguration.refresh()
            XCTAssertEqual(model.configurationDescription,
                           GitError.repositoryUnreadable(path: "fixture", detail: "beforeafter").localizedDescription)
        }
    }

    func testStrayEscapeDoesNotConsumeTabsOrPrintableUnicode() {
        XCTAssertEqual(DisplayTextSanitizer.logLine("a\u{1B}\tb"), "a\tb")
        XCTAssertEqual(DisplayTextSanitizer.logLine("a\u{1B}(\tb"), "a\tb")
        XCTAssertEqual(DisplayTextSanitizer.logLine("a\u{1B}é"), "aé")
    }

    func testStoredLogLinesAreSanitizedFromBothFiles() {
        let result = DaemonCLI.renderLog(
            current: "now failed \u{1B}[31mred\u{1B}[0m\u{7}\n",
            rotated: "old failed \u{1B}[32mgreen\u{1B}[0m\u{0}\n", lines: 20
        )
        XCTAssertEqual(result.output, "old failed green\nnow failed red\n")
        XCTAssertEqual(result.exitCode, 0)
    }
}

/// Models a volume vanishing at the entry lookup. All other operations are inert and do no host I/O.
private final class VanishingRootFiles: FileServiceProtocol {
    let root: String
    var vanished = false
    var reads: [String] = []
    init(root: String) { self.root = root }
    func directoryExists(at path: String) -> Bool {
        reads.append("directory")
        return !vanished
    }
    func entryExistsWithoutFollowingLinks(at path: String) throws -> Bool {
        XCTAssertEqual(path, root + "/.git")
        reads.append("entry")
        vanished = true
        return false
    }
    func readFile(at path: String) throws -> String { "" }
    func writeFile(at path: String, content: String) throws {}
    func writeExecutableFile(at path: String, content: String) throws {}
    func copyFile(at sourcePath: String, to destinationPath: String) throws {}
    func deleteFile(at path: String) throws {}
    func fileExists(at path: String) -> Bool { false }
    func isExecutableFile(at path: String) -> Bool { false }
    func isUserExecutableFile(at path: String) -> Bool { false }
    func createDirectory(at path: String) throws {}
    func deleteDirectory(at path: String) throws {}
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {}
    func symlinkTarget(at path: String) throws -> String { "" }
    func isSymlink(at path: String) -> Bool { false }
    func isRegularFile(at path: String) -> Bool { false }
    func listDirectory(at path: String) throws -> [String] { [] }
    func contentsHash(at path: String) throws -> String { "" }
}
