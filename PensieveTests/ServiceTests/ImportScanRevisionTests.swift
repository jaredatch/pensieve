import Darwin
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ImportScanRevisionTests: XCTestCase {
    func testRejectedFolderScanRetainsResultsAndTheirReport() {
        let scanner = RevisionReportScanner()
        let model = ImportViewModel(scanner: scanner)
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
        let root = NSTemporaryDirectory() + "ImportScanRevision-\(UUID().uuidString)"
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
        let root = NSTemporaryDirectory() + "ImportScanDirectory-\(UUID().uuidString)"
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
        let root = NSTemporaryDirectory() + "IS-\(UUID().uuidString.prefix(8))"
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
        let model = ImportViewModel(scanner: scanner)
        model.scan()

        XCTAssertEqual(model.doneTitle, "No Skills Imported")
        XCTAssertEqual(model.doneMessage, "No skills could be imported from the scanned entries.")
        XCTAssertEqual(model.scanSummary, "Skipped 3 entries: 3 symlinks or special files.")
        scanner.report = ImportScanReport()
        model.scan()
        XCTAssertEqual(model.doneTitle, "No Skills Found")
        XCTAssertEqual(model.doneMessage, "No existing skills were found. Create your first skill to get started.")
    }

    func testDoneMessageCountsSuccessfulImportsAndResetsForNextAttempt() throws {
        let scanner = RevisionReportScanner()
        scanner.report = ImportScanReport(skills: (0..<5).map { skill("skill-\($0)") })
        let store = RevisionSkillStore()
        store.failures = ["skill-1", "skill-3"]
        let model = ImportViewModel(scanner: scanner, skillStore: store)
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        model.scan()
        model.importSelected(context: container.mainContext)

        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<Skill>()).count, 3)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.doneTitle, "Import Finished")
        XCTAssertEqual(model.doneMessage, "3 skills imported into Pensieve.", "Count completed imports, not five selected skills")
        model.selectedSkills = ["skill-1"]
        store.failures = []
        model.importSelected(context: container.mainContext)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.doneMessage, "1 skill imported into Pensieve.", "A second import resets the completed count")
        model.scan()
        XCTAssertEqual(model.doneMessage, "0 skills imported into Pensieve.")
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

private final class RevisionSkillStore: SkillStoreProtocol {
    var failures: Set<String> = []
    func createSkill(name: String, description: String, body: String) throws -> String {
        if failures.contains(name) { throw CocoaError(.fileWriteNoPermission) }
        return name
    }
    func readBody(directoryName: String) throws -> String { throw CocoaError(.featureUnsupported) }
    func rewriteSkill(directoryName: String, body: String, preserving parsed: ParsedSkill,
                      fallbackName: String, fallbackDescription: String) throws { throw CocoaError(.featureUnsupported) }
    func writeBody(directoryName: String, body: String) throws { throw CocoaError(.featureUnsupported) }
    func deleteSkill(directoryName: String) throws { throw CocoaError(.featureUnsupported) }
    func listSkills() throws -> [String] { [] }
}
