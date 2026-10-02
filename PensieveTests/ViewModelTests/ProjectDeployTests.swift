import XCTest
import SwiftData
@testable import Pensieve

final class ProjectDeployTests: XCTestCase {

    private struct StubDetection: AgentDetectionServiceProtocol {
        let installed: [PlatformTarget]

        func isInstalled(_ platform: PlatformTarget) -> Bool { installed.contains(platform) }
        func installedPlatforms() -> [PlatformTarget] { installed }
    }

    private final class RecordingLinkService: LinkServiceProtocol {
        private(set) var lastLinkProjectPath: String?
        private(set) var lastUnlinkProjectPath: String?

        func link(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {
            lastLinkProjectPath = projectPath
        }

        func unlink(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {
            lastUnlinkProjectPath = projectPath
        }

        func isLinked(skill: Skill, platform: PlatformTarget, projectPath: String?) -> Bool { false }

        func linkPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
            (projectPath ?? "/tmp/user-wide") + "/links/" + skill.directoryName
        }

        func targetPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
            (projectPath ?? "/tmp/user-wide") + "/targets/" + skill.directoryName
        }

        func validateAll(skills: [Skill]) -> [BrokenLink] { [] }
    }

    private struct StubCursorCompiler: CursorCompilerProtocol {
        func compile(skill: Skill, projectPath: String?) throws {}
        func remove(skill: Skill, projectPath: String?) throws {}
        func isUpToDate(skill: Skill, projectPath: String?) -> Bool { false }
        func outputPath(skill: Skill, projectPath: String?) -> String {
            (projectPath ?? "/tmp/user-wide") + "/cursor/" + skill.directoryName + ".mdc"
        }
    }

    private struct StubFileService: FileServiceProtocol {
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

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self, DeployRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func makeViewModel(linkService: RecordingLinkService) -> PlatformViewModel {
        PlatformViewModel(
            fileService: StubFileService(),
            linkService: linkService,
            cursorCompiler: StubCursorCompiler(),
            agentDetection: StubDetection(installed: [])
        )
    }

    @MainActor
    func testProjectDeployRecordsProjectIDAndForwardsProjectPath() throws {
        let context = try makeContext()
        let skill = Skill(name: "Project Skill", directoryName: "project-skill")
        let project = Project(name: "Project X", path: "/tmp/proj-x")
        context.insert(skill)
        context.insert(project)

        let linkService = RecordingLinkService()
        let vm = makeViewModel(linkService: linkService)

        vm.deploy(skill: skill, platform: .claudeCode, target: .project(project), context: context)

        XCTAssertNil(vm.error)
        XCTAssertEqual(linkService.lastLinkProjectPath, "/tmp/proj-x")

        let records = try context.fetch(FetchDescriptor<DeployRecord>())
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(record.projectID, project.id)
    }

    @MainActor
    func testUserWideDeployRecordsNilProjectIDAndForwardsNilProjectPath() throws {
        let context = try makeContext()
        let skill = Skill(name: "User Skill", directoryName: "user-skill")
        context.insert(skill)

        let linkService = RecordingLinkService()
        let vm = makeViewModel(linkService: linkService)

        vm.deploy(skill: skill, platform: .claudeCode, target: .userWide, context: context)

        XCTAssertNil(vm.error)
        XCTAssertNil(linkService.lastLinkProjectPath)

        let records = try context.fetch(FetchDescriptor<DeployRecord>())
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(record.projectID)
    }

    @MainActor
    func testRemoveBatchForwardsDeployTargetProjectPath() throws {
        let context = try makeContext()
        let skill = Skill(name: "Remove Skill", directoryName: "remove-skill")
        let project = Project(name: "Project X", path: "/tmp/proj-x")
        context.insert(skill)
        context.insert(project)

        let projectLinkService = RecordingLinkService()
        let projectVM = makeViewModel(linkService: projectLinkService)
        _ = projectVM.removeBatch(skills: [skill], platforms: [.claudeCode], target: .project(project))
        XCTAssertEqual(projectLinkService.lastUnlinkProjectPath, project.path)

        let userLinkService = RecordingLinkService()
        let userVM = makeViewModel(linkService: userLinkService)
        _ = userVM.removeBatch(skills: [skill], platforms: [.claudeCode], target: .userWide)
        XCTAssertNil(userLinkService.lastUnlinkProjectPath)
    }

    func testDeployablePlatformsFiltersProjectUnsupportedAgents() {
        let installed: [PlatformTarget] = [.claudeCode, .codex, .cursor, .openClaw, .hermes]
        let vm = PlatformViewModel(agentDetection: StubDetection(installed: installed), deployStateStore: .memoryBacked)

        XCTAssertEqual(vm.deployablePlatforms(forProject: true), [.claudeCode, .codex, .cursor])
        XCTAssertEqual(vm.deployablePlatforms(forProject: false), installed)
    }
}
