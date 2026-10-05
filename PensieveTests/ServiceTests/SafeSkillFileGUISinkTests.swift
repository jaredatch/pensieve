import SwiftData
import XCTest
@testable import Pensieve

private typealias PensieveCategory = Pensieve.Category

final class SafeSkillFileGUISinkTests: XCTestCase {
    private var tempDir: String!
    private var fileService: FileService!

    override func setUpWithError() throws {
        tempDir = NSTemporaryDirectory() + "PensieveSafeSkillFileGUISinkTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        fileService = FileService()
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    @MainActor
    func testRebuildSkipsWarnsPreservesExistingRowAndAdmitsNoNewSymlinkLeaf() throws {
        let context = try makeContext()
        let existing = Skill(name: "Original", skillDescription: "original", directoryName: "victim")
        context.insert(existing)
        try writeEmptyManifest()
        try plantSymlinkedLeaf(slug: "victim", foreign: foreignSkill(name: "Foreign", description: "pwned"))
        try plantSymlinkedLeaf(slug: "newbie", foreign: foreignSkill(name: "Newbie", description: "pwned"))

        let result = StoreRebuildService(
            fileService: fileService,
            manifestService: ManifestService(fileService: fileService)
        ).rebuild(fromRoot: tempDir, context: context)

        XCTAssertEqual(result.skillsInserted, 0)
        XCTAssertEqual(result.skillsRemoved, 0)
        XCTAssertTrue(result.warnings.contains { $0.contains("victim") && $0.contains("not a regular file") })
        XCTAssertTrue(result.warnings.contains { $0.contains("newbie") && $0.contains("not a regular file") })
        let skills = try context.fetch(FetchDescriptor<Skill>())
        XCTAssertEqual(skills.map(\.directoryName), ["victim"])
        XCTAssertEqual(skills.first?.name, "Original")
    }

    @MainActor
    func testMigrationSkipsAndWarnsForSymlinkLeaf() throws {
        let context = try makeContext()
        let skill = Skill(name: "Original", skillDescription: "original", directoryName: "victim")
        context.insert(skill)
        try plantSymlinkedLeaf(slug: "victim", foreign: foreignSkill(name: "Foreign", description: "pwned"))

        let result = StoreMigrationService(
            fileService: fileService,
            manifestService: ManifestService(fileService: fileService),
            skillStore: SkillStore(fileService: fileService, baseDir: tempDir + "/skills")
        ).migrateIfNeeded(fromRoot: tempDir, context: context)

        XCTAssertEqual(result.skillsMigrated, 0)
        XCTAssertTrue(result.warnings.contains { $0.contains("victim") && $0.contains("safe regular file") })
        XCTAssertEqual(skill.name, "Original")
        XCTAssertEqual(try fileService.readFile(at: tempDir + "/outside/victim/SKILL.md"),
                       foreignSkill(name: "Foreign", description: "pwned"))
    }

    func testEstimatedTokensReturnsZeroAndDoesNotReadSymlinkLeaf() {
        let fs = LeafRejectingFileService()
        let skill = Skill(name: "Victim", skillDescription: "victim", directoryName: "victim")

        XCTAssertEqual(skill.estimatedTokens(using: fs), 0)
        XCTAssertTrue(fs.readPaths.isEmpty)
    }

    func testReadBodyThrowsUnsafeLeafInsteadOfReturningForeignBytes() throws {
        let foreign = "FOREIGN-BYTES-SHOULD-NOT-LOAD"
        try plantSymlinkedLeaf(slug: "victim", foreign: foreign)
        let store = SkillStore(fileService: fileService, baseDir: tempDir + "/skills")

        do {
            let body = try store.readBody(directoryName: "victim")
            XCTFail("readBody returned foreign content through the symlinked leaf: \(body)")
        } catch {
            XCTAssertEqual(error as? SkillStoreError, .unsafeLeaf("victim"))
        }
    }

    func testCursorCompilerIsUpToDateFalseAndCompileThrowsForSymlinkLeaf() throws {
        let foreign = foreignSkill(name: "Foreign", description: "pwned")
        try plantSymlinkedLeaf(slug: "victim", foreign: foreign)
        let store = SkillStore(fileService: fileService, baseDir: tempDir + "/skills")
        let compiler = CursorCompiler(fileService: fileService, skillStore: store)
        let skill = Skill(name: "Victim", skillDescription: "victim", directoryName: "victim")
        let projectPath = tempDir + "/project"
        let outputPath = compiler.outputPath(skill: skill, projectPath: projectPath)
        try fileService.writeFile(at: outputPath, content: "stale")

        XCTAssertFalse(compiler.isUpToDate(skill: skill, projectPath: projectPath))
        XCTAssertThrowsError(try compiler.compile(skill: skill, projectPath: projectPath)) {
            XCTAssertEqual($0 as? SkillStoreError, .unsafeLeaf("victim"))
        }
        XCTAssertEqual(try fileService.readFile(at: outputPath), "stale")
    }

    @MainActor
    func testDeployRefusesSymlinkPlatformBeforeLinkOrHash() throws {
        let context = try makeContext()
        let skill = Skill(name: "Victim", skillDescription: "victim", directoryName: "victim")
        context.insert(skill)
        let fs = LeafRejectingFileService()
        let link = SpyLinkService(linkRoot: tempDir + "/agent-links")
        let vm = PlatformViewModel(
            fileService: fs,
            linkService: link,
            cursorCompiler: NoopCursorCompiler(),
            agentDetection: StubDetection(),
            deployStateStore: DeployStateStore(fileService: fileService, appSupportDir: tempDir + "/app-support")
        )

        vm.deploy(skill: skill, platform: .claudeCode, target: .userWide, context: context)

        XCTAssertNotNil(vm.error)
        XCTAssertFalse(link.linkCalled)
        XCTAssertTrue(fs.hashPaths.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir + "/agent-links/victim"))
        XCTAssertEqual(try context.fetch(FetchDescriptor<DeployRecord>()).count, 0)
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self, DeployRecord.self, PensieveCategory.self, Scenario.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func writeEmptyManifest() throws {
        try ManifestService(fileService: fileService).write(
            ManifestSnapshot(schemaVersion: 1, categories: [], projects: [], skills: []),
            toRoot: tempDir
        )
    }

    private func plantSymlinkedLeaf(slug: String, foreign: String) throws {
        let skillDir = tempDir + "/skills/" + slug
        let outsideDir = tempDir + "/outside/" + slug
        try FileManager.default.createDirectory(atPath: skillDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outsideDir, withIntermediateDirectories: true)
        try fileService.writeFile(at: outsideDir + "/SKILL.md", content: foreign)
        try FileManager.default.createSymbolicLink(
            atPath: skillDir + "/SKILL.md",
            withDestinationPath: outsideDir + "/SKILL.md"
        )
    }

    private func foreignSkill(name: String, description: String) -> String {
        SkillSerializer.serialize(name: name, description: description, body: "# foreign")
    }
}

private final class LeafRejectingFileService: FileServiceProtocol {
    private(set) var readPaths: [String] = []
    private(set) var hashPaths: [String] = []

    func readFile(at path: String) throws -> String {
        readPaths.append(path)
        return "FOREIGN-BYTES-SHOULD-NOT-LOAD"
    }
    func writeFile(at path: String, content: String) throws {}
    func deleteFile(at path: String) throws {}
    func fileExists(at path: String) -> Bool { true }
    func isExecutableFile(at path: String) -> Bool { false }
    func directoryExists(at path: String) -> Bool { true }
    func createDirectory(at path: String) throws {}
    func deleteDirectory(at path: String) throws {}
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {}
    func symlinkTarget(at path: String) throws -> String { "" }
    func isSymlink(at path: String) -> Bool { path.hasSuffix("/SKILL.md") }
    func isRegularFile(at path: String) -> Bool { false }
    func listDirectory(at path: String) throws -> [String] { [] }
    func contentsHash(at path: String) throws -> String {
        hashPaths.append(path)
        return "hash"
    }
}

private final class SpyLinkService: LinkServiceProtocol {
    private(set) var linkCalled = false
    private let linkRoot: String

    init(linkRoot: String) {
        self.linkRoot = linkRoot
    }

    func link(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {
        linkCalled = true
        try FileManager.default.createDirectory(atPath: linkRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: linkRoot + "/" + skill.directoryName,
            withDestinationPath: "/tmp/should-not-be-linked"
        )
    }
    func unlink(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {}
    func ownsArtifact(skill: Skill, platform: PlatformTarget, projectPath: String?) throws -> Bool { false }

    func isLinked(skill: Skill, platform: PlatformTarget, projectPath: String?) -> Bool { false }
    func linkPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
        linkRoot + "/" + skill.directoryName
    }
    func targetPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
        "/tmp/should-not-be-linked"
    }
    func validateAll(skills: [Skill]) -> [BrokenLink] { [] }
}

private struct NoopCursorCompiler: CursorCompilerProtocol {
    func compile(skill: Skill, projectPath: String?) throws {}
    func remove(skill: Skill, projectPath: String?) throws {}
    func ruleMayExist(skill: Skill, projectPath: String?) throws -> Bool {
        try LinkService.validatePathComponent(skill.directoryName)
        return false
    }
    func ownsArtifact(skill: Skill, projectPath: String?) throws -> Bool { false }
    func hasOwnershipMark(skill: Skill, projectPath: String?) throws -> Bool { false }

    func isUpToDate(skill: Skill, projectPath: String?) -> Bool { false }
    func outputPath(skill: Skill, projectPath: String?) -> String { "/tmp/cursor/" + skill.directoryName + ".mdc" }
}

private struct StubDetection: AgentDetectionServiceProtocol {
    func isInstalled(_ platform: PlatformTarget) -> Bool { true }
    func installedPlatforms() -> [PlatformTarget] { PlatformTarget.allCases }
}
