import Darwin
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ImportPublicationTests: XCTestCase {
    private var root = ""
    private let files = FileService()
    private var storeRoot: String { root + "/store" }
    private var skillsOverride: String?
    private var skills: String { skillsOverride ?? storeRoot + "/skills" }
    private var lockPath: String { root + "/sync.lock" }

    override func setUpWithError() throws {
        root = TestTemporaryDirectory.path + "ImportPublication-" + UUID().uuidString
        try files.createDirectory(at: skills)
    }

    override func tearDownWithError() throws {
        try files.deleteDirectory(at: root)
    }

    private func context() throws -> ModelContext {
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func model(using service: FileServiceProtocol? = nil, names: [String] = ["One"],
                       manifestRoot: String? = nil) throws -> ImportViewModel {
        for name in names { try files.writeFile(at: root + "/sources/\(name)/SKILL.md", content: content(name)) }
        let service = service ?? files
        let scanner = ImportScanner(fileService: files, claudeSkillsDir: root + "/sources",
            grokSkillsDir: root + "/grok", cursorRulesDir: root + "/cursor", codexSkillsDir: root + "/codex",
            storeRoot: storeRoot)
        let model = ImportViewModel(scanner: scanner,
            skillStore: SkillStore(fileService: service, baseDir: skills, storeRoot: storeRoot), lockPath: lockPath,
            manifestRoot: manifestRoot ?? storeRoot)
        model.scan()
        return model
    }

    private func content(_ name: String) -> String {
        "---\nname: \(name)\ndescription: Description\n---\n\nBody \(name)\n"
    }

    private func temps() throws -> [String] {
        try files.listDirectory(at: root).filter { $0.hasPrefix("store.vendor-") }
    }

    func testReadersSeeOnlyCompleteSkillsAndLiveTempsSurviveSweepForTheBatch() throws {
        skillsOverride = root + "/alternate/library"
        let service = ImportPublicationFileService()
        var beforeNames: [String] = []
        var afterNames: [String] = []
        service.beforeWrite = { path, text in
            let name = text.contains("name: One\n") ? "one" : "two"
            beforeNames.append(name)
            XCTAssertFalse(try self.files.listDirectory(at: self.skills).contains(name))
            XCTAssertNil(SyncLock.tryAcquire(at: self.lockPath), "Lock precedes the first build and covers the next one")
            XCTAssertEqual((path as NSString).deletingLastPathComponent,
                self.root + "/" + (try XCTUnwrap(try self.temps().first)))
            SkillInstallService.cleanupVendorTemps(fileService: self.files, storeRoot: self.storeRoot, lockPath: self.lockPath)
            XCTAssertTrue(self.files.directoryExists(at: (path as NSString).deletingLastPathComponent))
        }
        service.afterWrite = { path, text in
            afterNames.append(text.contains("name: One\n") ? "one" : "two")
            XCTAssertEqual(try self.files.readFile(at: path), text)
            XCTAssertEqual(try self.files.listDirectory(at: self.skills).count, afterNames.count - 1)
            SkillInstallService.cleanupVendorTemps(fileService: self.files, storeRoot: self.storeRoot, lockPath: self.lockPath)
            XCTAssertTrue(self.files.fileExists(at: path))
        }
        let model = try model(using: service, names: ["One", "Two"], manifestRoot: root + "/unrelated-manifest")
        let context = try context()
        model.importSelected(context: context)

        XCTAssertNil(model.error)
        XCTAssertEqual(Set(beforeNames), ["one", "two"])
        XCTAssertEqual(Set(afterNames), ["one", "two"])
        XCTAssertEqual(service.directoryListings.filter { $0 == skills }.count, 1,
                       "One disk snapshot serves the locked batch")
        XCTAssertEqual(Set(try files.listDirectory(at: skills)), ["one", "two"])
        for name in ["One", "Two"] {
            XCTAssertEqual(try files.listDirectory(at: skills + "/" + name.lowercased()), ["SKILL.md"])
            XCTAssertEqual(try files.readFile(at: skills + "/" + name.lowercased() + "/SKILL.md"), content(name))
        }
        XCTAssertEqual(model.importedSkillCount, 2)
        XCTAssertTrue(try temps().isEmpty)
        let released = try XCTUnwrap(SyncLock.tryAcquire(at: lockPath))
        released.release()
    }

    func testAnotherProcessHoldingSyncLockRefusesImportWithoutWrites() async throws {
        let model = try model()
        let context = try context()
        let storeBefore = try files.listDirectory(at: storeRoot)
        let parentBefore = try files.listDirectory(at: root)
        let process = try startProbe("import-lock")
        defer { stop(process) }
        await TestWait.until(failureMessage: "Lock holder did not start") { self.files.fileExists(at: self.root + "/report") }
        XCTAssertTrue(process.isRunning)
        // The holder's lock and readiness files are the only additions to the parent snapshot.
        model.importSelected(context: context)
        XCTAssertTrue(model.error?.localizedCaseInsensitiveContains("sync is running") == true)
        XCTAssertEqual(model.importedSkillCount, 0)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Skill>()).isEmpty)
        XCTAssertTrue(try files.listDirectory(at: skills).isEmpty)
        XCTAssertEqual(try files.listDirectory(at: storeRoot), storeBefore)
        XCTAssertEqual(Set(try files.listDirectory(at: root)), Set(parentBefore + ["sync.lock", "report"]))
    }

    func testKilledBuildLeavesOnlyATempThatLaunchSweeps() async throws {
        let process = try startProbe("import-build")
        defer { stop(process) }
        await TestWait.until(failureMessage: "Import build did not reach its prepared-file boundary") {
            self.files.fileExists(at: self.root + "/report")
        }
        XCTAssertTrue(process.isRunning)
        let stagedFile = try files.readFile(at: root + "/report")
        XCTAssertEqual(try files.readFile(at: stagedFile),
            "---\nname: Crash\ndescription: Crash\n---\n\nComplete")
        XCTAssertEqual(try temps().count, 1)
        XCTAssertTrue(try files.listDirectory(at: skills).isEmpty)
        XCTAssertNil(SyncLock.tryAcquire(at: lockPath))
        stop(process)
        let released = try XCTUnwrap(SyncLock.tryAcquire(at: lockPath))
        released.release()

        let launch = LaunchReconciler(migrationService: StoreMigrationService(
            skillStore: SkillStore(fileService: files, baseDir: skills, storeRoot: storeRoot)),
            root: storeRoot, lockPath: lockPath, git: GitService(askpassHelperPath: root + "/askpass"))
        _ = launch.reconcileOnLaunch(context: try context(), alreadyMigrated: true)
        XCTAssertTrue(try temps().isEmpty)
        XCTAssertFalse(files.fileExists(at: stagedFile))
        XCTAssertTrue(try files.listDirectory(at: skills).isEmpty)
    }

    func testOccupiedSlugsKeepTheirEntryTypesAndBytes() throws {
        for kind in ["file", "link", "empty"] {
            let name = kind.capitalized
            let path = skills + "/" + kind
            try occupy(path, kind: kind)
            let identity = try XCTUnwrap(files.fileIdentity(at: path, followingLinks: false))
            let model = try model(names: [name])
            model.selectedSkills = Set(model.discoveredSkills.filter { $0.name == name }.map(\.sourcePath))
            let context = try context()
            model.importSelected(context: context)
            XCTAssertNil(model.error)
            XCTAssertEqual(try context.fetch(FetchDescriptor<Skill>()).map(\.directoryName), [kind + "-2"])
            try assertOccupant(path, kind: kind, identity: identity)
            XCTAssertEqual(try files.readFile(at: skills + "/" + kind + "-2/SKILL.md"), content(name))
        }
    }

    func testSlugClaimedDuringBuildIsNeverReplacedAndOtherSkillsImport() throws {
        for kind in ["file", "link", "empty"] {
            let name = "Race " + kind
            let slug = "race-" + kind
            let path = skills + "/" + slug
            let service = ImportPublicationFileService()
            var identity: FileIdentity?
            service.afterWrite = { _, text in
                if text.contains("name: \(name)\n") {
                    try self.occupy(path, kind: kind)
                    identity = self.files.fileIdentity(at: path, followingLinks: false)
                }
            }
            let model = try model(using: service, names: [name, "Good " + kind])
            model.selectedSkills = Set(model.discoveredSkills.filter {
                $0.name == name || $0.name == "Good " + kind
            }.map(\.sourcePath))
            let context = try context()
            model.importSelected(context: context)
            XCTAssertNotNil(model.error)
            XCTAssertEqual(model.importedSkillCount, 1)
            XCTAssertEqual(try context.fetch(FetchDescriptor<Skill>()).map(\.directoryName), ["good-" + kind])
            try assertOccupant(path, kind: kind, identity: XCTUnwrap(identity))
            XCTAssertTrue(try temps().isEmpty)
        }
    }

    func testPartialBuildAndPublishFailuresCleanUpAndContinue() throws {
        let service = ImportPublicationFileService()
        service.beforeWrite = { path, text in
            if text.contains("name: Bad Build\n") {
                try self.files.writeFile(at: path, content: "partial")
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        service.afterWrite = { path, text in
            if text.contains("name: Bad Publish\n") {
                // Removing only the prepared file's parent causes the real rename to fail with ENOENT.
                try self.files.deleteDirectory(at: (path as NSString).deletingLastPathComponent)
            }
        }
        let model = try model(using: service, names: ["Bad Build", "Bad Publish", "Good"])
        let context = try context()
        model.importSelected(context: context)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.importedSkillCount, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Skill>()).map(\.directoryName), ["good"])
        XCTAssertEqual(try files.listDirectory(at: skills), ["good"])
        XCTAssertEqual(try files.readFile(at: skills + "/good/SKILL.md"), content("Good"))
        XCTAssertTrue(try temps().isEmpty)
    }

    private func occupy(_ path: String, kind: String) throws {
        switch kind {
        case "file": try files.writeFile(at: path, content: "occupant bytes")
        case "link": try files.createSymlink(at: path, pointingTo: root + "/missing")
        default: try files.createDirectory(at: path)
        }
    }

    private func assertOccupant(_ path: String, kind: String, identity: FileIdentity) throws {
        XCTAssertEqual(files.fileIdentity(at: path, followingLinks: false), identity)
        switch kind {
        case "file":
            XCTAssertEqual(try files.entryTypeWithoutFollowingLinks(at: path), .regular)
            XCTAssertEqual(try files.readFile(at: path), "occupant bytes")
        case "link":
            XCTAssertTrue(files.isSymlink(at: path))
            XCTAssertEqual(try files.symlinkTarget(at: path), root + "/missing")
        default:
            XCTAssertEqual(try files.entryTypeWithoutFollowingLinks(at: path), .directory)
            XCTAssertTrue(try files.listDirectory(at: path).isEmpty)
        }
    }

    private func startProbe(_ mode: String) throws -> Process {
        let process = Process()
        process.executableURL = Bundle(for: Self.self).bundleURL.appendingPathComponent("Contents/MacOS/GitProcessProbe")
        process.arguments = [mode, root, root + "/report"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func stop(_ process: Process) {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}
