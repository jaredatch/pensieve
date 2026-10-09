import Darwin
import XCTest
@testable import Pensieve

final class ImportBoundedReadTests: XCTestCase {
    private let cap = 4 * 1_024 * 1_024
    private var root: String!
    private var spy: ImportBoundedReadSpy!

    override func setUpWithError() throws {
        root = TestTemporaryDirectory.path + "ImportBoundedReadTests-\(UUID().uuidString)"
        spy = ImportBoundedReadSpy()
        try spy.files.createDirectory(at: root)
        // Keep the fixture's store spelling physical when macOS returns a /var temp alias.
        root = spy.files.realPath(at: root)
    }

    override func tearDownWithError() throws {
        try spy.files.deleteDirectory(at: root)
        spy = nil
        root = nil
    }

    func testSmallPrefixReadAllocatesOnlyFileSizePlusOne() throws {
        let path = root + "/small"
        try spy.files.writeFile(at: path, content: "abc")
        var allocated = 0
        let data = try spy.files.readRegularFilePrefix(at: path, maximumBytes: 64 * 1_024 * 1_024) {
            allocated = $0
        }
        XCTAssertEqual(String(data: data, encoding: .utf8), "abc")
        XCTAssertEqual(allocated, 4, "The retained prefix allocation is min(bound, file size) + 1")
        let prefix = try spy.files.readRegularFilePrefix(at: path, maximumBytes: 1)
        XCTAssertEqual(String(data: prefix, encoding: .utf8), "ab")
    }

    func testPrefixGrowthAfterFstatReadsUntilEofOrTheLookaheadByte() throws {
        let path = root + "/growth"
        for maximum in [6, 12] {
            try spy.files.writeFile(at: path, content: "abc")
            var grew = false
            let data = try spy.files.readRegularFilePrefix(at: path, maximumBytes: maximum) { _ in
                guard !grew else { return }
                let writer = open(path, O_WRONLY | O_APPEND)
                defer { close(writer) }
                XCTAssertGreaterThanOrEqual(writer, 0)
                let extra = Array("defgh".utf8)
                XCTAssertEqual(extra.withUnsafeBytes { Darwin.write(writer, $0.baseAddress, $0.count) }, extra.count)
                grew = true
            }
            XCTAssertTrue(grew)
            XCTAssertEqual(String(data: data, encoding: .utf8), maximum == 6 ? "abcdefg" : "abcdefgh")
            XCTAssertEqual(data.count > maximum, maximum == 6, "Lookahead must mean content continues beyond the bound")
        }
    }

    func testCursorSpecialLeavesAreNotReadAndOtherRulesRemain() throws {
        let rules = root + "/cursor"
        try spy.files.writeFile(at: rules + "/good.mdc", content: "# Good rule")
        try spy.files.writeFile(at: root + "/target", content: "linked sentinel")
        try spy.files.createSymlink(at: rules + "/linked.mdc", pointingTo: root + "/target")
        try spy.files.createSymlink(at: rules + "/dangling.mdc", pointingTo: root + "/missing")
        try spy.files.createDirectory(at: rules + "/directory.mdc")
        let fifo = rules + "/pipe.mdc"
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        spy.devicePath = rules + "/device.mdc"
        let scanner = makeScanner()

        let skills = try boundedImportScan(fifo: fifo) { scanner.scan() }

        XCTAssertEqual(skills.map(\.name), ["good"])
        XCTAssertTrue(spy.textReads.isEmpty)
        XCTAssertEqual(Set(spy.consumed.keys), [rules + "/good.mdc"])
        let report = scanner.scanWithReport()
        XCTAssertEqual(report.skipped.count, 5)
        XCTAssertTrue(report.skipped.allSatisfy { $0.reason == .notRegular })
    }

    func testOversizedRegularAndSparseSkillsAndRulesAreSkipped() throws {
        for source in ["claude", "grok", "codex", "cursor", "folder"] {
            let directory = root + "/" + source
            let good = source == "cursor" ? directory + "/good.mdc" : directory + "/good/SKILL.md"
            try spy.files.writeFile(at: good, content: "# Good")
            for sparse in [false, true] {
                let name = sparse ? "sparse" : "large"
                let path = source == "cursor" ? directory + "/\(name).mdc" : directory + "/\(name)/SKILL.md"
                if sparse {
                    try makeSparseFile(path, bytes: cap + 1)
                } else {
                    try spy.files.writeData(at: path, data: Data(repeating: 65, count: cap + 1))
                }
            }
        }
        let scanner = makeScanner()
        let report = scanner.scanWithReport()
        let folderReport = scanner.scanFolderWithReport(root + "/folder")
        let skills = report.skills + folderReport.skills

        XCTAssertEqual(report.skipped.count, 8)
        XCTAssertEqual(folderReport.skipped.count, 2)
        XCTAssertTrue((report.skipped + folderReport.skipped).allSatisfy { $0.reason == .tooLarge })
        XCTAssertEqual(skills.count, 5)
        XCTAssertTrue(skills.allSatisfy { $0.name == "good" })
        XCTAssertTrue(spy.textReads.isEmpty)
        // The chosen collection's missing SKILL.md is also decided by one descriptor attempt.
        XCTAssertEqual(spy.limits.count, 16)
        XCTAssertTrue(spy.limits.values.allSatisfy { $0 == cap })
        for (path, count) in spy.consumed {
            XCTAssertLessThanOrEqual(count, cap + 1, path)
            XCTAssertTrue(path.contains("/good"), path)
        }
    }

    func testGrowthAfterOpenStopsAtCapPlusOneAndKeepsOtherSkills() throws {
        for cursor in [false, true] {
            let path = cursor ? root + "/cursor/growing.mdc" : root + "/claude/growing/SKILL.md"
            try makeSparseFile(path, bytes: cap)
            let good = cursor ? root + "/cursor/good.mdc" : root + "/claude/good/SKILL.md"
            try spy.files.writeFile(at: good, content: "# Good")
            spy.growPath = path
            spy.growthSize = cap + 64 * 1_024
            let scanner = makeScanner()
            let report = scanner.scanWithReport()
            let skills = report.skills

            XCTAssertEqual(report.skipped, [ImportScanSkip(path: path, reason: .tooLarge)])
            XCTAssertFalse(skills.contains { $0.sourcePath == path })
            XCTAssertTrue(skills.contains { $0.sourcePath == good })
            XCTAssertNil(spy.growPath, "The mutation must land after descriptor admission")
            XCTAssertEqual(spy.files.regularFileMetadata(at: path)?.byteCount, spy.growthSize)
            XCTAssertEqual(spy.consumed[path], cap + 1)
            XCTAssertEqual(spy.requests[path]?.last, 1)
            try spy.files.deleteFile(at: path)
        }
    }

    func testBoundedReaderAllowsExactCapEmptyAndUnlimitedReads() throws {
        let path = root + "/file"
        for limit in [0, 1, 65_537] {
            let bytes = Data(repeating: 65, count: limit)
            try spy.files.writeData(at: path, data: bytes)
            XCTAssertEqual(try spy.readRegularFileData(at: path, maximumBytes: limit), bytes)
            XCTAssertEqual(spy.requests[path]?.last, 1)
        }
        XCTAssertEqual(try spy.files.readRegularFileData(at: path, maximumBytes: Int.max), Data(repeating: 65, count: 65_537))
    }

    func testBoundedReaderRejectsRealDeviceBeforeReading() {
        var reads = 0
        XCTAssertThrowsError(try spy.files.readRegularFileData(at: "/dev/null", maximumBytes: cap) { _, _, _ in
            reads += 1
            return 0
        })
        XCTAssertEqual(reads, 0)
    }

    func testScanAcceptsFilesAtFourMiBLimit() throws {
        let paths = [root + "/claude/exact/SKILL.md", root + "/cursor/exact.mdc"]
        for path in paths { try spy.files.writeData(at: path, data: Data(repeating: 65, count: cap)) }

        let report = makeScanner().scanWithReport()

        XCTAssertEqual(Set(report.skills.map(\.sourcePath)), Set(paths))
        XCTAssertTrue(report.skipped.isEmpty)
        for path in paths {
            XCTAssertEqual(spy.consumed[path], cap)
            XCTAssertEqual(spy.requests[path]?.last, 1)
        }
    }

    func testReportReachesModelAndResetsOnLaterScans() throws {
        let rules = root + "/cursor"
        try spy.files.writeFile(at: rules + "/good.mdc", content: "# Good")
        try spy.files.writeFile(at: rules + "/unreadable.mdc", content: "# Unreadable")
        spy.unreadablePath = rules + "/unreadable.mdc"
        try spy.files.writeData(at: rules + "/invalid.mdc", data: Data([0xFF]))
        try spy.files.createSymlink(at: rules + "/link.mdc", pointingTo: "good.mdc")
        try makeSparseFile(rules + "/huge.mdc", bytes: cap + 1)
        try spy.files.writeFile(at: root + "/claude/README.md", content: "Ordinary collection file")
        try spy.files.createDirectory(at: root + "/claude/empty-folder")
        let model = ImportViewModel(
            scanner: makeScanner(),
            skillStore: SkillStore(fileService: FileService(), baseDir: TestPaths.skillsDir, storeRoot: TestPaths.storeRoot),
            lockPath: TestTemporaryDirectory.path + "import-lock-" + UUID().uuidString,
            manifestRoot: TestPaths.storeRoot
        )
        model.scan()

        XCTAssertEqual(model.discoveredSkills.map(\.name), ["good"])
        XCTAssertEqual(model.scanSkips.count, 4)
        XCTAssertEqual(Set(model.scanSkips.map(\.reason)), Set(ImportScanSkip.Reason.allCases))
        let retained = model.discoveredSkills
        let retainedSkips = model.scanSkips
        XCTAssertEqual(model.scanFolder(root + "/missing"), .nothingFound)
        XCTAssertEqual(model.discoveredSkills, retained)
        XCTAssertEqual(model.scanSkips, retainedSkips, "Rejected scans must retain the matching report")
        model.scan()
        XCTAssertEqual(model.scanSkips.count, 4)
        XCTAssertEqual(model.scanFolder(root + "/store"), .insideLibrary)
        XCTAssertEqual(model.discoveredSkills, retained)
        XCTAssertEqual(model.scanSkips, retainedSkips, "Library refusal must retain the matching report")
    }

}

extension ImportBoundedReadTests {
    func testAllSkippedFolderKeepsNothingFoundAndDoesNotWidenDanglingLeaf() throws {
        let collection = root + "/folder"
        try spy.files.writeFile(at: collection + "/child/SKILL.md", content: "Child")
        try spy.files.createSymlink(at: collection + "/SKILL.md", pointingTo: root + "/absent")
        let model = ImportViewModel(
            scanner: makeScanner(),
            skillStore: SkillStore(fileService: FileService(), baseDir: TestPaths.skillsDir, storeRoot: TestPaths.storeRoot),
            lockPath: TestTemporaryDirectory.path + "import-lock-" + UUID().uuidString,
            manifestRoot: TestPaths.storeRoot
        )

        XCTAssertEqual(model.scanFolder(collection), .nothingFound)
        XCTAssertTrue(model.discoveredSkills.isEmpty)
        XCTAssertEqual(model.scanSkips, [ImportScanSkip(path: collection + "/SKILL.md", reason: .notRegular)])
    }

    func testForwardingSpiesRefuseResolvedLibraryRootBeforeReads() throws {
        let library = root + "/library"
        let alias = root + "/library-alias"
        try spy.files.writeFile(at: library + "/skill/SKILL.md", content: "Library skill")
        try spy.files.createSymlink(at: alias, pointingTo: library)
        let wholeFileSpy = ImportReadSpy(files: spy.files)
        let forwardingSpies: [FileServiceProtocol] = [spy, wholeFileSpy]
        for files in forwardingSpies {
            let scanner = ImportScanner(
                fileService: files, claudeSkillsDir: root + "/claude", grokSkillsDir: root + "/grok",
                cursorRulesDir: root + "/cursor", codexSkillsDir: root + "/codex", storeRoot: alias
            )
            let model = ImportViewModel(
                scanner: scanner,
                skillStore: SkillStore(fileService: FileService(), baseDir: TestPaths.skillsDir, storeRoot: TestPaths.storeRoot),
                lockPath: TestTemporaryDirectory.path + "import-lock-" + UUID().uuidString,
            manifestRoot: TestPaths.storeRoot
            )
            XCTAssertEqual(model.scanFolder(library), .insideLibrary)
            XCTAssertTrue(model.discoveredSkills.isEmpty)
            XCTAssertTrue(model.scanSkips.isEmpty)
        }
        XCTAssertTrue(spy.limits.isEmpty)
        XCTAssertTrue(spy.textReads.isEmpty)
        XCTAssertTrue(wholeFileSpy.returnedBytes.isEmpty)
    }

    func testGrowthWithShortAndInterruptedReadsStaysWithinLimit() throws {
        let path = root + "/short"
        let limit = 65_537
        try makeSparseFile(path, bytes: limit)
        var consumed = 0
        var calls = 0
        XCTAssertThrowsError(try spy.files.readRegularFileData(at: path, maximumBytes: limit) { descriptor, buffer, count in
            calls += 1
            if calls == 1 {
                let writer = open(path, O_WRONLY)
                XCTAssertGreaterThanOrEqual(writer, 0)
                if writer >= 0 {
                    XCTAssertEqual(ftruncate(writer, off_t(limit + 1_000)), 0)
                    close(writer)
                }
                errno = EINTR
                return -1
            }
            let result = Darwin.read(descriptor, buffer, min(count, 13))
            consumed += max(result, 0)
            return result
        })
        XCTAssertGreaterThan(calls, 2)
        XCTAssertEqual(consumed, limit + 1)
        XCTAssertEqual(spy.files.regularFileMetadata(at: path)?.byteCount, limit + 1_000)
    }

    private func makeSparseFile(_ path: String, bytes: Int) throws {
        try spy.files.writeData(at: path, data: Data())
        // Fixture-only sparse file creation. No production path bypasses FileService.
        let descriptor = open(path, O_WRONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        XCTAssertEqual(ftruncate(descriptor, off_t(bytes)), 0)
    }

    private func makeScanner() -> ImportScanner {
        ImportScanner(
            fileService: spy,
            claudeSkillsDir: root + "/claude",
            grokSkillsDir: root + "/grok",
            cursorRulesDir: root + "/cursor",
            codexSkillsDir: root + "/codex",
            storeRoot: root + "/store"
        )
    }
}
