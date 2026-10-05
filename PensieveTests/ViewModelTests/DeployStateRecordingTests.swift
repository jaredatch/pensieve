import SwiftData
import XCTest
@testable import Pensieve

final class DeployStateRecordingTests: XCTestCase {
    private struct StubDetection: AgentDetectionServiceProtocol {
        func isInstalled(_ platform: PlatformTarget) -> Bool { true }
        func installedPlatforms() -> [PlatformTarget] { PlatformTarget.allCases }
    }

    private struct CleanFileService: FileServiceProtocol {
        func readFile(at path: String) throws -> String { "" }
        func writeFile(at path: String, content: String) throws {}
        func deleteFile(at path: String) throws {}
        func fileExists(at path: String) -> Bool { false }
        func isExecutableFile(at path: String) -> Bool { false }
        func directoryExists(at path: String) -> Bool { false }
        func createDirectory(at path: String) throws {}
        func deleteDirectory(at path: String) throws {}
        func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {}
        func symlinkTarget(at path: String) throws -> String { "" }
        func isSymlink(at path: String) -> Bool { false }
        func isRegularFile(at path: String) -> Bool { true }
        func listDirectory(at path: String) throws -> [String] { [] }
        func contentsHash(at path: String) throws -> String { "hash" }
    }

    private final class RecordingLinkService: LinkServiceProtocol {
        let root: String
        init(root: String) { self.root = root }

        func link(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {}
        func unlink(skill: Skill, platform: PlatformTarget, projectPath: String?) throws -> Bool { false }
        func ownsArtifact(skill: Skill, platform: PlatformTarget, projectPath: String?) throws -> Bool { false }

        func isLinked(skill: Skill, platform: PlatformTarget, projectPath: String?) -> Bool { false }
        func linkPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
            (projectPath ?? root + "/user") + "/links/" + platform.rawValue + "/" + skill.directoryName
        }
        func targetPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
            (projectPath ?? root + "/user") + "/targets/" + platform.rawValue + "/" + skill.directoryName
        }
        func validateAll(skills: [Skill]) -> [BrokenLink] { [] }
    }

    private struct RecordingCursorCompiler: CursorCompilerProtocol {
        let root: String
        func compile(skill: Skill, projectPath: String?) throws {}
        func remove(skill: Skill, projectPath: String?) throws -> Bool { false }
        func probeRulePresence(skill: Skill, projectPath: String?) throws -> Bool {
            return false
        }
        func ownsArtifact(skill: Skill, projectPath: String?) throws -> Bool { false }
        func hasOwnershipMark(skill: Skill, projectPath: String?) throws -> Bool { false }

        func isUpToDate(skill: Skill, projectPath: String?) -> Bool { false }
        func outputPath(skill: Skill, projectPath: String?) -> String {
            (projectPath ?? root + "/user") + "/cursor/" + skill.directoryName + ".mdc"
        }
    }

    private var tempDir: String!
    private var fileService: FileService!
    private var store: DeployStateStore!

    override func setUpWithError() throws {
        tempDir = NSTemporaryDirectory() + "PensieveDeployStateRecordingTests-\(UUID().uuidString)"
        fileService = FileService()
        store = DeployStateStore(fileService: fileService, appSupportDir: tempDir + "/app-support")
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    @MainActor
    func testDeployAndRemoveMaintainArtifactForSymlinkCursorAndProjectScopes() throws {
        let context = try makeContext()
        let skill = insertedSkill("Alpha", slug: "alpha", context: context)
        let project = insertedProject("Project", path: tempDir + "/project", identityKey: "project-key", context: context)
        let vm = makeViewModel()

        vm.deploy(skill: skill, platform: .claudeCode, target: .userWide, context: context)
        var records = try store.read().records
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.slug, "alpha")
        XCTAssertEqual(records.first?.platform, PlatformTarget.claudeCode.rawValue)
        XCTAssertEqual(records.first?.scope, "user")
        XCTAssertNil(records.first?.projectIdentityKey)

        vm.remove(skill: skill, platform: .claudeCode, target: .userWide)
        XCTAssertTrue(try store.read().records.isEmpty)

        vm.deploy(skill: skill, platform: .cursor, target: .userWide, context: context)
        records = try store.read().records
        XCTAssertEqual(records.map(\.artifactPath), [tempDir + "/user/cursor/alpha.mdc"])
        XCTAssertEqual(records.first?.platform, PlatformTarget.cursor.rawValue)

        vm.remove(skill: skill, platform: .cursor, target: .userWide)
        XCTAssertTrue(try store.read().records.isEmpty)

        vm.deploy(skill: skill, platform: .codex, target: .project(project), context: context)
        records = try store.read().records
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.scope, "project")
        XCTAssertEqual(records.first?.projectIdentityKey, "project-key")
        XCTAssertEqual(records.first?.artifactPath, tempDir + "/project/links/codex/alpha")

        vm.remove(skill: skill, platform: .codex, target: .project(project))
        XCTAssertTrue(try store.read().records.isEmpty)
    }

    @MainActor
    func testProjectDeployWithNilIdentityKeySkipsRecord() throws {
        let context = try makeContext()
        let skill = insertedSkill("Alpha", slug: "alpha", context: context)
        let project = insertedProject("Project", path: tempDir + "/project", identityKey: nil, context: context)
        let vm = makeViewModel()

        vm.deploy(skill: skill, platform: .claudeCode, target: .project(project), context: context)

        XCTAssertNil(vm.error)
        XCTAssertTrue(try store.read().records.isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DeployRecord>()).count, 1)
    }

    @MainActor
    func testArtifactWriteFailureDoesNotFailDeployOrTouchNewerSchemaBytes() throws {
        let context = try makeContext()
        let skill = insertedSkill("Alpha", slug: "alpha", context: context)
        let statePath = tempDir + "/app-support/deploy-state.json"
        let newer = #"{"records":[],"schema_version":2}"#
        try fileService.writeFile(at: statePath, content: newer)
        let vm = makeViewModel()

        vm.deploy(skill: skill, platform: .cursor, target: .userWide, context: context)

        XCTAssertNil(vm.error)
        XCTAssertEqual(try fileService.readFile(at: statePath), newer)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DeployRecord>()).count, 1)
    }

    private func makeViewModel() -> PlatformViewModel {
        PlatformViewModel(
            fileService: CleanFileService(),
            linkService: RecordingLinkService(root: tempDir),
            cursorCompiler: RecordingCursorCompiler(root: tempDir),
            agentDetection: StubDetection(),
            deployStateStore: store,
            now: { Date(timeIntervalSince1970: 1_784_332_800) }
        )
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self, DeployRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @MainActor
    private func insertedSkill(_ name: String, slug: String, context: ModelContext) -> Skill {
        let skill = Skill(name: name, directoryName: slug)
        context.insert(skill)
        return skill
    }

    @MainActor
    private func insertedProject(
        _ name: String,
        path: String,
        identityKey: String?,
        context: ModelContext
    ) -> Project {
        let project = Project(name: name, path: path)
        project.identityKey = identityKey
        context.insert(project)
        return project
    }
}
