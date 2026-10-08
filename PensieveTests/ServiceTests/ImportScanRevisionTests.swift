import Darwin
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ImportScanRevisionTests: XCTestCase {
    func testOversizedSkipLabelsFollowTheScannerByteLimit() {
        let cap = ImportScanner.maximumFileBytes / (1_024 * 1_024)
        XCTAssertEqual(ImportScanSkip.Reason.tooLarge.label(count: 1), "file larger than \(cap) MiB")
        XCTAssertEqual(ImportScanSkip.Reason.tooLarge.label(count: 2), "files larger than \(cap) MiB")
    }

    func testAllSkippedNoticeExplainsScanDepthBeforeLatestFolderSummary() {
        let scanner = RevisionReportScanner()
        scanner.report = ImportScanReport(skipped: [.init(path: "skip", reason: .tooLarge)])
        let model = ImportViewModel(
            scanner: scanner,
            skillStore: SkillStore(fileService: FileService(), baseDir: TestPaths.skillsDir),
            lockPath: TestTemporaryDirectory.path + "import-lock-" + UUID().uuidString,
            manifestRoot: TestPaths.storeRoot
        )
        XCTAssertEqual(model.scanFolder("/chosen"), .nothingFound)
        XCTAssertEqual(model.nothingFoundMessage(folder: "Chosen"),
                       "Chosen holds no readable SKILL.md. Pensieve looks in it and in its folders, never deeper.\n\n"
                       + "Chosen: Skipped 1 entry: 1 file larger than 4 MiB.")
    }

    func testNothingFoundNoticeUsesLatestFolderSkipsWhileRetainingEarlierResultsAndReport() {
        let scanner = RevisionReportScanner()
        let model = ImportViewModel(
            scanner: scanner,
            skillStore: SkillStore(fileService: FileService(), baseDir: TestPaths.skillsDir),
            lockPath: TestTemporaryDirectory.path + "import-lock-" + UUID().uuidString,
            manifestRoot: TestPaths.storeRoot
        )
        scanner.report = ImportScanReport(skills: [skill("old")], skipped: [.init(path: "old", reason: .notRegular)])
        model.scan()
        let oldSummary = model.scanSummary
        scanner.report = ImportScanReport(skipped: [.init(path: "new", reason: .tooLarge),
                                                  .init(path: "denied", reason: .unreadable)])
        XCTAssertEqual(model.scanFolder("/chosen"), .nothingFound)
        XCTAssertEqual(model.nothingFoundMessage(folder: "Chosen"),
                       "Chosen holds no readable SKILL.md. Pensieve looks in it and in its folders, never deeper.\n\n"
                       + "Chosen: Skipped 2 entries: 1 file larger than 4 MiB; 1 unreadable file or folder.")
        XCTAssertEqual(model.discoveredSkills.map(\.name), ["old"])
        XCTAssertEqual(model.scanSummary, oldSummary)
        scanner.report = ImportScanReport(skipped: [.init(path: "one", reason: .invalidUTF8)])
        let fresh = ImportViewModel(
            scanner: scanner,
            skillStore: SkillStore(fileService: FileService(), baseDir: TestPaths.skillsDir),
            lockPath: TestTemporaryDirectory.path + "import-lock-" + UUID().uuidString,
            manifestRoot: TestPaths.storeRoot
        )
        XCTAssertEqual(fresh.scanFolder("/new"), .nothingFound)
        XCTAssertEqual(fresh.nothingFoundMessage(folder: "New"),
                       "New holds no readable SKILL.md. Pensieve looks in it and in its folders, never deeper.\n\n"
                       + "New: Skipped 1 entry: 1 file that isn't UTF-8 text.")
        scanner.report = ImportScanReport()
        XCTAssertEqual(fresh.scanFolder("/empty"), .nothingFound)
        XCTAssertEqual(fresh.nothingFoundMessage(folder: "Empty"),
                       "Empty holds no readable SKILL.md. Pensieve looks in it and in its folders, never deeper.")
    }

    func testRejectedFolderScanRetainsResultsAndTheirReport() {
        let scanner = RevisionReportScanner()
        let model = ImportViewModel(
            scanner: scanner,
            skillStore: SkillStore(fileService: FileService(), baseDir: TestPaths.skillsDir),
            lockPath: TestTemporaryDirectory.path + "import-lock-" + UUID().uuidString,
            manifestRoot: TestPaths.storeRoot
        )
        scanner.report = ImportScanReport(skills: [skill("old")], skipped: [.init(path: "old-skip", reason: .notRegular)])
        model.scan()
        let retained = model.discoveredSkills
        let retainedSkips = model.scanSkips
        scanner.report = ImportScanReport(skipped: [.init(path: "new-skip", reason: .tooLarge)])

        XCTAssertEqual(model.scanFolder("/empty"), .nothingFound)
        XCTAssertEqual(model.discoveredSkills, retained)
        XCTAssertEqual(model.scanSkips, retainedSkips, "Old results must keep their own scan's skips")
        XCTAssertEqual(model.scanFolder("/library"), .insideLibrary)
        XCTAssertEqual(model.discoveredSkills, retained)
        XCTAssertEqual(model.scanSkips, retainedSkips, "A refused scan must not clear the retained report")

        scanner.report = ImportScanReport(skills: [skill("new")], skipped: [.init(path: "new-skip", reason: .invalidUTF8)])
        XCTAssertEqual(model.scanFolder("/found"), .found(1))
        XCTAssertEqual(model.discoveredSkills, scanner.report.skills)
        XCTAssertEqual(model.scanSkips, scanner.report.skipped)
        scanner.report = ImportScanReport()
        model.scan()
        XCTAssertTrue(model.discoveredSkills.isEmpty)
        XCTAssertNil(model.scanSummary)
    }

    func testDescriptorErrorsDecideEachLeafWithoutAdmissionProbes() throws {
        let spy = ImportBoundedReadSpy()
        let root = TestTemporaryDirectory.path + "ImportScanRevision-\(UUID().uuidString)"
        defer { try? spy.files.deleteDirectory(at: root) }
        let directory = root + "/claude"
        let failures: [DescriptorFailure] = [
            .init(name: "gone", code: ENOENT, reason: nil),
            .init(name: "parent-gone", code: ENOTDIR, reason: nil),
            .init(name: "link", code: ELOOP, reason: .notRegular),
            .init(name: "device", code: EFTYPE, reason: .notRegular),
            .init(name: "directory", code: EISDIR, reason: .notRegular),
            .init(name: "denied", code: EACCES, reason: .unreadable)
        ]
        for failure in failures {
            let path = directory + "/\(failure.name)/SKILL.md"
            try spy.files.writeFile(at: path, content: "A regular file before the descriptor read")
            spy.readFailures[path] = failure.code
        }
        let good = directory + "/good/SKILL.md"
        try spy.files.writeFile(at: good, content: "Good")
        try spy.files.writeFile(at: directory + "/README.md", content: "Ordinary collection entry")

        let report = scanner(spy, root: root).scanWithReport()

        XCTAssertEqual(report.skills.map(\.sourcePath), [good])
        let expected = failures.compactMap { failure in
            failure.reason.map { ImportScanSkip(path: directory + "/\(failure.name)/SKILL.md", reason: $0) }
        }
        XCTAssertEqual(Set(report.skipped.map(\.path)), Set(expected.map(\.path)))
        for skip in expected { XCTAssertTrue(report.skipped.contains(skip), "Descriptor error must classify \(skip.path)") }
        XCTAssertTrue(spy.regularProbes.isEmpty, "Each leaf is decided by its descriptor, without lstat admission")
        XCTAssertTrue(spy.presenceProbes.isEmpty, "Missing leaves are decided by the descriptor read")
        XCTAssertFalse(spy.directoryProbes.contains { $0.hasPrefix(directory + "/") },
                       "No child-directory admission probe")
        let expectedAttempts = Set(
            failures.map { directory + "/\($0.name)/SKILL.md" } + [good, directory + "/README.md/SKILL.md"]
        )
        XCTAssertEqual(Set(spy.readAttempts), expectedAttempts)
        XCTAssertEqual(spy.readAttempts.count, expectedAttempts.count, "Exactly one descriptor attempt per candidate")
    }

    func testDirectoryNamedSkillMarkdownStillScansChildSkills() throws {
        let spy = ImportBoundedReadSpy()
        let root = TestTemporaryDirectory.path + "ImportScanDirectory-\(UUID().uuidString)"
        defer { try? spy.files.deleteDirectory(at: root) }
        let folder = root + "/chosen"
        try spy.files.createDirectory(at: folder + "/SKILL.md")
        let child = folder + "/child/SKILL.md"
        try spy.files.writeFile(at: child, content: "Child skill")

        let report = scanner(spy, root: root).scanFolderWithReport(folder)

        XCTAssertEqual(report.skills.map(\.sourcePath), [child], "A directory named SKILL.md must not hide the children")
        XCTAssertTrue(report.skipped.isEmpty, "The chosen folder's SKILL.md directory is a container, not a skipped leaf")
        XCTAssertEqual(spy.readAttempts.filter { $0 == folder + "/SKILL.md" }.count, 1)
        XCTAssertTrue(spy.presenceProbes.isEmpty)
    }

    func testSocketLeafIsReportedAsSpecialWithoutReading() throws {
        let spy = ImportBoundedReadSpy()
        // The system temp path keeps the UNIX socket below sun_path's limit regardless of checkout length.
        let root = TestTemporaryDirectory.systemPath + "IS-\(UUID().uuidString.prefix(8))"
        defer { try? spy.files.deleteDirectory(at: root) }
        let path = root + "/cursor/socket.mdc"
        let good = root + "/cursor/good.mdc"
        try spy.files.writeFile(at: good, content: "Good rule")
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        // Fixture-only socket creation; admission and attempted reads use production FileService.
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        XCTAssertLessThan(path.utf8.count, capacity)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    _ = strlcpy($0, source, capacity)
                }
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(result, 0)

        let report = scanner(spy, root: root).scanWithReport()

        XCTAssertEqual(report.skills.map(\.sourcePath), [good])
        XCTAssertEqual(report.skipped, [.init(path: path, reason: .notRegular)])
        XCTAssertEqual(spy.readAttempts.filter { $0 == path }.count, 1)
        XCTAssertNil(spy.requests[path], "Socket admission must fail before the read syscall")
        XCTAssertNil(spy.consumed[path])
        XCTAssertTrue(spy.textReads.isEmpty)
    }

    func testDoneMessageAcknowledgesAllSkippedEntries() {
        let scanner = RevisionReportScanner()
        scanner.report = ImportScanReport(skipped: (0..<3).map { .init(path: "skip-\($0)", reason: .notRegular) })
        let model = ImportViewModel(
            scanner: scanner,
            skillStore: SkillStore(fileService: FileService(), baseDir: TestPaths.skillsDir),
            lockPath: TestTemporaryDirectory.path + "import-lock-" + UUID().uuidString,
            manifestRoot: TestPaths.storeRoot
        )
        model.scan()

        XCTAssertEqual(model.doneTitle, "No Skills Imported")
        XCTAssertEqual(model.doneMessage, "No skills could be imported from the scanned entries.")
        XCTAssertEqual(model.scanSummary, "Skipped 3 entries: 3 symlinks or special files.")
        scanner.report = ImportScanReport()
        model.scan()
        XCTAssertEqual(model.doneTitle, "No Skills Found")
        XCTAssertEqual(model.doneMessage, "No existing skills were found. Create your first skill to get started.")
    }

}

extension ImportScanRevisionTests {
    func testDoneMessageCountsSuccessfulImportsAndResetsForNextAttempt() throws {
        let scanner = RevisionReportScanner()
        scanner.report = ImportScanReport(skills: (0..<5).map { skill("skill-\($0)") })
        let root = TestTemporaryDirectory.path + "ImportDone-" + UUID().uuidString
        let files = ImportPublicationFileService()
        defer { try? files.files.deleteDirectory(at: root) }
        let store = SkillStore(fileService: files, baseDir: root + "/skills")
        files.beforeWrite = { _, content in
            if content.contains("name: skill-1\n") || content.contains("name: skill-3\n") {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        let model = ImportViewModel(scanner: scanner, skillStore: store,
            lockPath: TestTemporaryDirectory.path + "import-lock-" + UUID().uuidString,
            manifestRoot: root)
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        model.scan()
        model.importSelected(context: container.mainContext)

        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<Skill>()).count, 3)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.doneTitle, "Import Finished")
        XCTAssertEqual(model.doneMessage, "3 skills imported into Pensieve.", "Count completed imports, not five selected skills")
        model.selectedSkills = ["skill-1"]
        files.beforeWrite = { _, _ in }
        model.importSelected(context: container.mainContext)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.doneMessage, "1 skill imported into Pensieve.", "A second import resets the completed count")
        model.scan()
        XCTAssertEqual(model.doneMessage, "0 skills imported into Pensieve.")
    }

    func testFailedLibrarySaveDoesNotPublishSuccessfulImports() throws {
        let scanner = RevisionReportScanner()
        scanner.report = ImportScanReport(skills: (0..<5).map { skill("skill-\($0)") })
        let root = TestTemporaryDirectory.path + "ImportSave-" + UUID().uuidString
        let files = FileService()
        defer { try? files.deleteDirectory(at: root) }
        let store = SkillStore(fileService: files, baseDir: root + "/skills")
        var notifications = 0
        var echoes: [[String]] = []
        let model = ImportViewModel(
            scanner: scanner,
            skillStore: store,
            lockPath: TestTemporaryDirectory.path + "import-lock-" + UUID().uuidString,
            manifestRoot: root,
            notifier: { notifications += 1 },
            echoRegistrar: { echoes.append($0) }
        )
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        model.scan()
        var saves = 0
        model.importSelected(context: context, saveContext: { pending in
            saves += 1
            XCTAssertEqual(pending.insertedModelsArray.count, 5)
            throw CocoaError(.fileWriteUnknown)
        })

        XCTAssertEqual(saves, 1)
        XCTAssertEqual(try files.listDirectory(at: root + "/skills").count, 5,
                       "All five file creates succeed before the failed save")
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Skill>()).count, 0)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.importedSkillCount, 0, "The done count must reflect saved library rows")
        XCTAssertEqual(model.doneMessage, "0 skills imported into Pensieve.")
        XCTAssertEqual(model.doneTitle, "Import Finished")
        XCTAssertEqual(notifications, 0)
        XCTAssertTrue(echoes.isEmpty)
    }

    func testImportCountIsPublishedOnlyAfterTheLibrarySaveSucceeds() throws {
        let scanner = RevisionReportScanner()
        scanner.report = ImportScanReport(skills: (0..<5).map { skill("skill-\($0)") })
        let root = TestTemporaryDirectory.path + "ImportCount-" + UUID().uuidString
        let files = FileService()
        defer { try? files.deleteDirectory(at: root) }
        let model = ImportViewModel(scanner: scanner,
            skillStore: SkillStore(fileService: files, baseDir: root + "/skills"),
            lockPath: TestTemporaryDirectory.path + "import-lock-" + UUID().uuidString,
            manifestRoot: root)
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        model.scan()
        model.importSelected(context: context, saveContext: { pending in
            XCTAssertEqual(model.importedSkillCount, 0, "Unsaved insertions are not completed imports")
            try pending.save()
        })

        XCTAssertNil(model.error)
        XCTAssertEqual(model.importedSkillCount, 5)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Skill>()).count, 5)
        XCTAssertEqual(model.doneMessage, "5 skills imported into Pensieve.")
    }

    private func skill(_ name: String) -> DiscoveredSkill {
        DiscoveredSkill(name: name, body: name, sourcePlatform: "folder", sourcePath: name, skillDescription: nil)
    }

    private func scanner(_ files: FileServiceProtocol, root: String) -> ImportScanner {
        ImportScanner(fileService: files, claudeSkillsDir: root + "/claude", grokSkillsDir: root + "/grok",
                      cursorRulesDir: root + "/cursor", codexSkillsDir: root + "/codex", storeRoot: root + "/store")
    }
}

private struct DescriptorFailure {
    let name: String
    let code: Int32
    let reason: ImportScanSkip.Reason?
}

private final class RevisionReportScanner: ImportScannerProtocol {
    var report = ImportScanReport()
    func scan() -> [DiscoveredSkill] { report.skills }
    func scanFolder(_ path: String) -> [DiscoveredSkill] { report.skills }
    func scanWithReport() -> ImportScanReport { report }
    func scanFolderWithReport(_ path: String) -> ImportScanReport { report }
    func isInsideStore(_ path: String) -> Bool { path == "/library" }
}
