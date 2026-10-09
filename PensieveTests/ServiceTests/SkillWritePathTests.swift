import SwiftData
import XCTest
@testable import Pensieve

private typealias PensieveCategory = Pensieve.Category

private final class WritePathScanner: ImportScannerProtocol {
    let skills: [DiscoveredSkill]
    var folderSkills: [DiscoveredSkill] = []
    var insideStore = false
    private(set) var scanFolderCalls = 0

    init(skills: [DiscoveredSkill]) {
        self.skills = skills
    }

    func scan() -> [DiscoveredSkill] { skills }
    func scanFolder(_ path: String) -> [DiscoveredSkill] {
        scanFolderCalls += 1
        return folderSkills
    }
    func isInsideStore(_ path: String) -> Bool { insideStore }
}

final class SkillWritePathTests: XCTestCase {
    private var tempDir: String!
    private var fileService: FileService!
    private var store: SkillStore!

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.path + "PensieveWritePathTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        fileService = FileService()
        store = SkillStore(fileService: fileService, baseDir: tempDir, storeRoot: tempDir)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self, DeployRecord.self, PensieveCategory.self, Scenario.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func rawFile(_ dirName: String) throws -> String {
        try fileService.readFile(at: tempDir + "/" + dirName + "/SKILL.md")
    }

    // MARK: - Create

    @MainActor
    func testCreateWritesFrontmatterPlusBody() throws {
        let context = try makeContext()
        let vm = SkillLibraryViewModel(
            skillStore: store, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir), manifestRoot: TestPaths.storeRoot
        )
        vm.createSkill(name: "My Skill", description: "Does a thing", body: "# Hello",
                       tags: [], context: context)

        let parsed = SkillParser.parse(try rawFile("my-skill"))
        XCTAssertTrue(parsed.hasRequiredFrontmatter)
        XCTAssertEqual(parsed.name, "My Skill")
        XCTAssertEqual(parsed.description, "Does a thing")
        XCTAssertEqual(parsed.body, "# Hello")
    }

    @MainActor
    func testCreateWithNoDescriptionFallsBackToName() throws {
        let context = try makeContext()
        let vm = SkillLibraryViewModel(
            skillStore: store, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir), manifestRoot: TestPaths.storeRoot
        )
        vm.createSkill(name: "Lonely", description: "", body: "# Body",
                       tags: [], context: context)

        let parsed = SkillParser.parse(try rawFile("lonely"))
        XCTAssertEqual(parsed.description, "Lonely")
        XCTAssertTrue(parsed.hasRequiredFrontmatter)
        let skills = try context.fetch(FetchDescriptor<Skill>())
        XCTAssertEqual(skills.first?.skillDescription, "Lonely")
    }

    @MainActor
    func testCreateReturnsTheSkillItInserted() throws {
        let context = try makeContext()
        let vm = SkillLibraryViewModel(
            skillStore: store, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir), manifestRoot: TestPaths.storeRoot
        )
        let created = vm.createSkill(name: "Fresh", description: "", body: "# b",
                                     tags: [], context: context)
        let inserted = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
        XCTAssertEqual(created?.id, inserted.id)
        XCTAssertEqual(created?.directoryName, "fresh")
    }

    /// The create path fingerprints the body the way the store reads it back (canonical: newlines trimmed at both
    /// ends), so the watcher's event for the new file is recognized as Pensieve's own write. A raw fingerprint with
    /// the sheet's trailing newline read the app's own create as "Modified externally — reloaded".
    @MainActor
    func testCreateFingerprintsTheBodyAsTheWatcherReadsIt() throws {
        let context = try makeContext()
        let vm = SkillLibraryViewModel(
            skillStore: store, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir), manifestRoot: TestPaths.storeRoot
        )
        vm.createSkill(name: "Echo", description: "", body: "# Echo\n\nText.\n",
                       tags: [], context: context)
        let onDisk = vm.currentOnDiskBody(directoryName: "echo")
        XCTAssertTrue(vm.wasLastWrittenByApp(directoryName: "echo", currentBody: onDisk))
    }

    // MARK: - Edit/save preserves frontmatter (the silent-loss regression)

    @MainActor
    func testEditPreservesFrontmatter() throws {
        let context = try makeContext()
        let vm = SkillLibraryViewModel(
            skillStore: store, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir), manifestRoot: TestPaths.storeRoot
        )
        vm.createSkill(name: "Editable", description: "Original desc", body: "# v1",
                       tags: [], context: context)
        let skill = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)

        XCTAssertTrue(vm.updateBody(skill, body: "# v2").succeeded)

        let parsed = SkillParser.parse(try rawFile("editable"))
        XCTAssertEqual(parsed.name, "Editable")
        XCTAssertEqual(parsed.description, "Original desc")
        XCTAssertEqual(parsed.body, "# v2")
        XCTAssertTrue(parsed.hasRequiredFrontmatter)
    }

    // MARK: - Import (Claude: frontmatter name differs from directory entry)

    @MainActor
    func testImportClaudeUsesFrontmatterNameAndDescription() throws {
        let claudeDir = tempDir + "/claude-src"
        let entryDir = claudeDir + "/dir-entry-name"
        try fileService.createDirectory(at: entryDir)
        try fileService.writeFile(
            at: entryDir + "/SKILL.md",
            content: "---\nname: Real Frontmatter Name\ndescription: The real description\n---\n\n# Imported body\n"
        )
        let scanner = ImportScanner(
            fileService: fileService,
            claudeSkillsDir: claudeDir,
            grokSkillsDir: tempDir + "/none-grok",
            cursorRulesDir: tempDir + "/none",
            codexSkillsDir: tempDir + "/none-codex",
            storeRoot: TestPaths.storeRoot
        )
        let vm = ImportViewModel(scanner: scanner, skillStore: store,
            lockPath: TestTemporaryDirectory.path + "import-lock-" + UUID().uuidString,
            manifestRoot: TestPaths.storeRoot)
        let context = try makeContext()
        vm.scan()
        vm.importSelected(context: context)

        let skill = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
        XCTAssertEqual(skill.name, "Real Frontmatter Name")
        XCTAssertEqual(skill.skillDescription, "The real description")
        let parsed = SkillParser.parse(try rawFile(skill.directoryName))
        XCTAssertEqual(parsed.name, "Real Frontmatter Name")
        XCTAssertEqual(parsed.description, "The real description")
        XCTAssertEqual(parsed.body, "# Imported body")
    }

    // MARK: - Import (Cursor: description from the MDC)

    @MainActor
    func testImportCursorLiftsDescription() throws {
        let cursorDir = tempDir + "/cursor-src"
        try fileService.createDirectory(at: cursorDir)
        try fileService.writeFile(
            at: cursorDir + "/my-rule.mdc",
            content: "---\ndescription: A cursor rule desc\nalwaysApply: false\n---\n\n# Rule body\n"
        )
        let scanner = ImportScanner(
            fileService: fileService,
            claudeSkillsDir: tempDir + "/none",
            grokSkillsDir: tempDir + "/none-grok",
            cursorRulesDir: cursorDir,
            codexSkillsDir: tempDir + "/none-codex",
            storeRoot: TestPaths.storeRoot
        )
        let vm = ImportViewModel(scanner: scanner, skillStore: store,
            lockPath: TestTemporaryDirectory.path + "import-lock-" + UUID().uuidString,
            manifestRoot: TestPaths.storeRoot)
        let context = try makeContext()
        vm.scan()
        vm.importSelected(context: context)

        let skill = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
        XCTAssertEqual(skill.skillDescription, "A cursor rule desc")
        let parsed = SkillParser.parse(try rawFile(skill.directoryName))
        XCTAssertEqual(parsed.description, "A cursor rule desc")
    }

    // MARK: - Import (bare body, no frontmatter -> synthesize with name-as-description)

    @MainActor
    func testImportBareBodySynthesizesFrontmatter() throws {
        let claudeDir = tempDir + "/claude-bare"
        let entryDir = claudeDir + "/bare-skill"
        try fileService.createDirectory(at: entryDir)
        try fileService.writeFile(at: entryDir + "/SKILL.md", content: "# Just a body, no frontmatter\n")
        let scanner = ImportScanner(
            fileService: fileService,
            claudeSkillsDir: claudeDir,
            grokSkillsDir: tempDir + "/none-grok",
            cursorRulesDir: tempDir + "/none",
            codexSkillsDir: tempDir + "/none-codex",
            storeRoot: TestPaths.storeRoot
        )
        let vm = ImportViewModel(scanner: scanner, skillStore: store,
            lockPath: TestTemporaryDirectory.path + "import-lock-" + UUID().uuidString,
            manifestRoot: TestPaths.storeRoot)
        let context = try makeContext()
        vm.scan()
        vm.importSelected(context: context)

        let skill = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
        XCTAssertEqual(skill.name, "bare-skill")
        XCTAssertEqual(skill.skillDescription, "bare-skill")
        let parsed = SkillParser.parse(try rawFile(skill.directoryName))
        XCTAssertTrue(parsed.hasRequiredFrontmatter)
        XCTAssertEqual(parsed.name, "bare-skill")
        XCTAssertEqual(parsed.description, "bare-skill")
    }

    // MARK: - Edit of a legacy empty-description skill backfills to name (07.2 review fix)

    @MainActor
    func testEditOfLegacyEmptyDescriptionBackfillsToName() throws {
        // A legacy/default skill carries an empty `skillDescription` (pre-migration state) and a
        // body-only SKILL.md. Editing it must NOT write a rebuild-inadmissible empty description —
        // the save path falls back to the name, matching create/import, and backfills the row too.
        let context = try makeContext()
        let vm = SkillLibraryViewModel(
            skillStore: store, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir), manifestRoot: TestPaths.storeRoot
        )
        try fileService.createDirectory(at: tempDir + "/legacy")
        try fileService.writeFile(at: tempDir + "/legacy/SKILL.md", content: "# old body")
        let skill = Skill(name: "Legacy", directoryName: "legacy")   // skillDescription defaults to ""
        context.insert(skill)

        XCTAssertTrue(vm.updateBody(skill, body: "# new body").succeeded)

        let parsed = SkillParser.parse(try rawFile("legacy"))
        XCTAssertEqual(parsed.name, "Legacy")
        XCTAssertEqual(parsed.description, "Legacy")          // fallback to name, not empty
        XCTAssertTrue(parsed.hasRequiredFrontmatter)          // rebuild-admissible
        XCTAssertEqual(parsed.body, "# new body")
        XCTAssertEqual(skill.skillDescription, "Legacy")      // the row was backfilled too
    }

    @MainActor
    func testImportAvoidsExistingRowSlugs() throws {
        let context = try makeContext()
        context.insert(Skill(name: "Existing", directoryName: "Foo"))
        try context.save()
        let discovered = [
            DiscoveredSkill(name: "Foo", body: "one", sourcePlatform: "test", sourcePath: "/one"),
            DiscoveredSkill(name: "Foo", body: "two", sourcePlatform: "test", sourcePath: "/two")
        ]

        let vm = ImportViewModel(scanner: WritePathScanner(skills: discovered), skillStore: store,
            lockPath: TestTemporaryDirectory.path + "import-lock-" + UUID().uuidString,
            manifestRoot: TestPaths.storeRoot)
        vm.scan()

        vm.importSelected(context: context)

        XCTAssertEqual(try fileService.listDirectory(at: tempDir).sorted(), ["foo-2", "foo-3"])
        XCTAssertEqual(SkillParser.stripFrontmatter(try rawFile("foo-2")), "one")
        XCTAssertEqual(SkillParser.stripFrontmatter(try rawFile("foo-3")), "two")
        let slugs = try context.fetch(FetchDescriptor<Skill>()).map(\.directoryName)
        XCTAssertEqual(Set(slugs), ["Foo", "foo-2", "foo-3"])
    }

    @MainActor
    func testImportAbortsWhenRowsCannotBeFetched() throws {
        let context = try makeContext()
        let discovered = [
            DiscoveredSkill(name: "One", body: "one", sourcePlatform: "test", sourcePath: "/one"),
            DiscoveredSkill(name: "Two", body: "two", sourcePlatform: "test", sourcePath: "/two")
        ]
        let before = try fileService.listDirectory(at: tempDir)
        let vm = ImportViewModel(scanner: WritePathScanner(skills: discovered), skillStore: store,
            lockPath: TestTemporaryDirectory.path + "import-lock-" + UUID().uuidString,
            manifestRoot: TestPaths.storeRoot)
        vm.scan()
        vm.importProgress = 0.5

        vm.importSelected(context: context, takenSlugs: { _ in throw DeletionTestError() })

        XCTAssertEqual(try fileService.listDirectory(at: tempDir), before)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Skill>()).isEmpty)
        XCTAssertTrue(vm.error?.contains("couldn't read the library") == true)
        XCTAssertEqual(vm.importProgress, 0.5)
    }
}

extension SkillWritePathTests {
    @MainActor
    func testImportSeedsTagsFromFrontmatterIntoOverlayNotFile() throws {
        let context = try makeContext()
        let discovered = DiscoveredSkill(
            name: "Tagged",
            body: "# Body",
            sourcePlatform: "claude-code",
            sourcePath: "/tagged",
            skillDescription: "Tagged fixture",
            tags: ["Swift", "swift", "review"]
        )
        let scanner = WritePathScanner(skills: [discovered])
        let manifest = ManifestService(fileService: fileService)
        let vm = ImportViewModel(
            scanner: scanner,
            skillStore: store,
            lockPath: TestTemporaryDirectory.path + "import-lock-" + UUID().uuidString,
            manifestService: manifest, manifestRoot: tempDir
        )
        vm.scan()

        vm.importSelected(context: context)

        let skill = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
        XCTAssertEqual(skill.tags, ["Swift", "review"])
        let overlay = try XCTUnwrap(
            try manifest.read(fromRoot: tempDir).skills.first { $0.slug == skill.directoryName }
        )
        XCTAssertEqual(overlay.tags, ["Swift", "review"])
        XCTAssertTrue(SkillParser.parse(try rawFile(skill.directoryName)).tags.isEmpty)
    }

    @MainActor
    func testScanFolderImportsAsFolderOrigin() throws {
        let context = try makeContext()
        let discovered = DiscoveredSkill(
            name: "Folder Skill",
            body: "# Body",
            sourcePlatform: "folder",
            sourcePath: "/folder/SKILL.md"
        )
        let scanner = WritePathScanner(skills: [])
        scanner.folderSkills = [discovered]
        let vm = ImportViewModel(scanner: scanner, skillStore: store,
            lockPath: TestTemporaryDirectory.path + "import-lock-" + UUID().uuidString,
            manifestRoot: TestPaths.storeRoot)

        XCTAssertEqual(vm.scanFolder("/folder"), .found(1))
        vm.importSelected(context: context)

        let skill = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
        XCTAssertEqual(skill.importedFrom, "folder")
    }

    @MainActor
    func testScanFolderOutcomesLeaveResultsUntouched() throws {
        let discovered = DiscoveredSkill(
            name: "Folder Skill",
            body: "# Body",
            sourcePlatform: "folder",
            sourcePath: "/folder/SKILL.md"
        )
        let scanner = WritePathScanner(skills: [])
        scanner.folderSkills = [discovered]
        let vm = ImportViewModel(scanner: scanner, skillStore: store,
            lockPath: TestTemporaryDirectory.path + "import-lock-" + UUID().uuidString,
            manifestRoot: TestPaths.storeRoot)

        XCTAssertEqual(vm.scanFolder("/folder"), .found(1))
        let originalResults = vm.discoveredSkills
        scanner.folderSkills = []
        XCTAssertEqual(vm.scanFolder("/empty"), .nothingFound)
        XCTAssertEqual(vm.discoveredSkills, originalResults)

        scanner.insideStore = true
        let callsBeforeRefusal = scanner.scanFolderCalls
        XCTAssertEqual(vm.scanFolder("/library"), .insideLibrary)
        XCTAssertEqual(scanner.scanFolderCalls, callsBeforeRefusal)
        XCTAssertEqual(vm.discoveredSkills, originalResults)
    }
}
