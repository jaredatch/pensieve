import SwiftData
import XCTest
@testable import Pensieve

final class PlatformViewModelTests: XCTestCase {

    private struct StubDetection: AgentDetectionServiceProtocol {
        let installed: [PlatformTarget]
        func isInstalled(_ platform: PlatformTarget) -> Bool { installed.contains(platform) }
        func installedPlatforms() -> [PlatformTarget] { installed }
    }

    func testInstalledPlatformsReflectsInjectedDetection() {
        let vm = PlatformViewModel(agentDetection: StubDetection(installed: [.claudeCode, .hermes]),
                                   deployStateStore: .memoryBacked)
        XCTAssertEqual(vm.installedPlatforms(), [.claudeCode, .hermes])
    }

    func testInstalledPlatformsEmptyWhenNoneDetected() {
        let vm = PlatformViewModel(agentDetection: StubDetection(installed: []), deployStateStore: .memoryBacked)
        XCTAssertEqual(vm.installedPlatforms(), [])
    }

    private struct SymlinkFileService: FileServiceProtocol {
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
        func isSymlink(at path: String) -> Bool { true }   // canonical slug dir looks symlinked
        func listDirectory(at path: String) throws -> [String] { [] }
        func contentsHash(at path: String) throws -> String { "hash" }
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
        func isSymlink(at path: String) -> Bool { false }   // NOT a symlink - only component validation catches "../evil"
        func isRegularFile(at path: String) -> Bool { true }
        func listDirectory(at path: String) throws -> [String] { [] }
        func contentsHash(at path: String) throws -> String { "hash" }
    }

    private final class NoopLinkService: LinkServiceProtocol {
        var linked = false
        private(set) var linkProjectPaths: [String?] = []
        private(set) var unlinkProjectPaths: [String?] = []

        func link(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {
            linkProjectPaths.append(projectPath)
        }

        func unlink(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {
            unlinkProjectPaths.append(projectPath)
        }

        func isLinked(skill: Skill, platform: PlatformTarget, projectPath: String?) -> Bool { linked }
        func linkPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
            "/tmp/link/" + skill.directoryName
        }
        func targetPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
            "/tmp/target/" + skill.directoryName
        }
        func validateAll(skills: [Skill]) -> [BrokenLink] { [] }
    }

    private struct StubCursorCompiler: CursorCompilerProtocol {
        func compile(skill: Skill, projectPath: String?) throws {}
        func remove(skill: Skill, projectPath: String?) throws {}
        func isUpToDate(skill: Skill, projectPath: String?) -> Bool { false }
        func outputPath(skill: Skill, projectPath: String?) -> String {
            "/tmp/cursor/" + skill.directoryName + ".mdc"
        }
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
    func testDeployRefusesSymlinkedCanonicalDirAndWritesNoRecord() throws {
        let context = try makeContext()
        let skill = Skill(name: "Victim", directoryName: "victim")
        context.insert(skill)
        let vm = PlatformViewModel(
            fileService: SymlinkFileService(),   // isSymlink == true
            linkService: NoopLinkService(),
            cursorCompiler: StubCursorCompiler(),
            agentDetection: DeployStubDetection(installed: []), deployStateStore: .memoryBacked
        )

        let refreshBefore = vm.refreshCounter
        vm.deploy(skill: skill, platform: .claudeCode, target: .userWide, context: context)

        XCTAssertNotNil(vm.error)
        XCTAssertEqual(vm.refreshCounter, refreshBefore + 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DeployRecord>()).count, 0)
    }

    @MainActor
    func testDeployRefusesTraversingCanonicalDirNameEvenWhenNotSymlink() throws {
        let context = try makeContext()
        // "../evil" is a traversing component the old `!isSymlink`-only guard accepted; the shared
        // C7 resolver rejects it on component validation even though the dir is not a symlink.
        let skill = Skill(name: "Evil", directoryName: "../evil")
        context.insert(skill)
        let vm = PlatformViewModel(
            fileService: CleanFileService(),   // isSymlink == false - old guard would have deployed
            linkService: NoopLinkService(),
            cursorCompiler: StubCursorCompiler(),
            agentDetection: DeployStubDetection(installed: []), deployStateStore: .memoryBacked
        )

        vm.deploy(skill: skill, platform: .claudeCode, target: .userWide, context: context)

        XCTAssertNotNil(vm.error)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DeployRecord>()).count, 0)
    }

    @MainActor
    func testToggleDeployDeploysWhenAbsent() throws {
        let context = try makeContext()
        let skill = Skill(name: "Toggle Skill", directoryName: "toggle-skill")
        context.insert(skill)
        let linkService = NoopLinkService()
        let vm = PlatformViewModel(
            fileService: CleanFileService(),
            linkService: linkService,
            cursorCompiler: StubCursorCompiler(),
            agentDetection: DeployStubDetection(installed: []), deployStateStore: .memoryBacked
        )
        let refreshBefore = vm.refreshCounter

        vm.toggleDeploy(
            skill: skill,
            platform: .claudeCode,
            target: .userWide,
            context: context
        )

        XCTAssertEqual(linkService.linkProjectPaths.count, 1)
        XCTAssertNil(linkService.linkProjectPaths[0])
        XCTAssertTrue(linkService.unlinkProjectPaths.isEmpty)
        XCTAssertEqual(vm.refreshCounter, refreshBefore + 1)
    }

    @MainActor
    func testToggleDeployRemovesWhenPresent() throws {
        let context = try makeContext()
        let skill = Skill(name: "Toggle Skill", directoryName: "toggle-skill")
        let project = Project(name: "Project", path: "/tmp/project")
        context.insert(skill)
        context.insert(project)
        let linkService = NoopLinkService()
        linkService.linked = true
        let vm = PlatformViewModel(
            fileService: CleanFileService(),
            linkService: linkService,
            cursorCompiler: StubCursorCompiler(),
            agentDetection: DeployStubDetection(installed: []), deployStateStore: .memoryBacked
        )
        let refreshBefore = vm.refreshCounter

        vm.toggleDeploy(
            skill: skill,
            platform: .claudeCode,
            target: .project(project),
            context: context
        )

        XCTAssertEqual(linkService.unlinkProjectPaths, [project.path])
        XCTAssertTrue(linkService.linkProjectPaths.isEmpty)
        XCTAssertEqual(vm.refreshCounter, refreshBefore + 1)
    }

    private func deletionRoot() throws -> String {
        let root = TestTemporaryDirectory.path + "PlatformDelete-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        return root
    }

    private func stateRecord(path: String, platform: PlatformTarget = .claudeCode) -> DeployStateRecord {
        DeployStateRecord(
            slug: "alpha", platform: platform.rawValue, scope: "user",
            projectIdentityKey: nil, artifactPath: path, recordedAt: "2026-08-27T00:00:00Z"
        )
    }

    private func deletionVM(
        installed: [PlatformTarget], link: DeletionTestLinkService,
        cursor: DeletionTestCursorCompiler = DeletionTestCursorCompiler(), store: DeployStateStore
    ) -> PlatformViewModel {
        PlatformViewModel(
            fileService: CleanFileService(), linkService: link, cursorCompiler: cursor,
            agentDetection: DeletionTestDetection(installed: installed), deployStateStore: store
        )
    }
}

extension PlatformViewModelTests {
    @MainActor
    func testRemoveAllDeploysRemovesEveryLinkedSymlink() throws {
        let root = try deletionRoot(), store = DeployStateStore(fileService: FileService(), appSupportDir: root)
        let skill = Skill(name: "Alpha", directoryName: "alpha")
        let project = Project(name: "P", path: "/project")
        let link = DeletionTestLinkService()
        let pairs: [(PlatformTarget, String?)] = [(.claudeCode, nil), (.codex, nil), (.claudeCode, project.path)]
        link.linkedPaths = Set(pairs.map { link.path(skill, $0.0, $0.1) })
        try store.replaceAll(pairs.map { stateRecord(path: link.path(skill, $0.0, $0.1), platform: $0.0) })
        let vm = deletionVM(installed: [.claudeCode, .codex], link: link, store: store)
        let result = vm.removeAllDeploys(skill: skill, projects: [project])
        XCTAssertEqual(result.successes.count, 3)
        XCTAssertEqual(link.unlinkCalls.map(\.1), [nil, nil, project.path])
        XCTAssertTrue(try store.read().records.isEmpty)
        XCTAssertEqual(vm.refreshCounter, 1)
    }

    @MainActor
    func testRemoveAllDeploysSkipsAbsentArtifacts() throws {
        let store = DeployStateStore(fileService: FileService(), appSupportDir: try deletionRoot())
        let link = DeletionTestLinkService()
        let vm = deletionVM(installed: [.claudeCode], link: link, store: store)
        let result = vm.removeAllDeploys(skill: Skill(name: "A", directoryName: "a"), projects: [])
        XCTAssertTrue(result.outcomes.isEmpty)
        XCTAssertTrue(link.unlinkCalls.isEmpty)
        XCTAssertEqual(vm.refreshCounter, 0)
    }

    @MainActor
    func testRemoveAllDeploysDropsStaleRecordWithoutTouchingPath() throws {
        let store = DeployStateStore(fileService: FileService(), appSupportDir: try deletionRoot())
        let skill = Skill(name: "A", directoryName: "a"), link = DeletionTestLinkService()
        let path = link.path(skill, .claudeCode, nil)
        link.foreignSymlinkPaths.insert(path)
        try store.replaceAll([stateRecord(path: path)])
        let result = deletionVM(installed: [.claudeCode], link: link, store: store)
            .removeAllDeploys(skill: skill, projects: [])
        XCTAssertEqual(result.successes.count, 1)
        XCTAssertTrue(link.unlinkCalls.isEmpty)
        XCTAssertTrue(try store.read().records.isEmpty)
    }

    @MainActor
    func testRemoveAllDeploysReportsMixedOutcomes() throws {
        let store = DeployStateStore(fileService: FileService(), appSupportDir: try deletionRoot())
        let skill = Skill(name: "A", directoryName: "a"), project = Project(name: "P", path: "/p")
        let link = DeletionTestLinkService()
        let user = link.path(skill, .claudeCode, nil), scoped = link.path(skill, .claudeCode, project.path)
        link.linkedPaths = [user, scoped]; link.failingUnlinkPaths = [scoped]
        try store.replaceAll([stateRecord(path: user), stateRecord(path: scoped)])
        let vm = deletionVM(installed: [.claudeCode], link: link, store: store)
        let result = vm.removeAllDeploys(skill: skill, projects: [project])
        XCTAssertEqual(result.successes.count, 1); XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(try store.read().records.map(\.artifactPath), [scoped])
        XCTAssertEqual(vm.refreshCounter, 1)
    }

    @MainActor
    func testRemoveAllDeploysLeavesForeignSymlinkAlone() throws {
        let store = DeployStateStore(fileService: FileService(), appSupportDir: try deletionRoot())
        let skill = Skill(name: "A", directoryName: "a"), link = DeletionTestLinkService()
        link.foreignSymlinkPaths.insert(link.path(skill, .claudeCode, nil))
        let vm = deletionVM(installed: [.claudeCode], link: link, store: store)
        XCTAssertTrue(vm.removeAllDeploys(skill: skill, projects: []).outcomes.isEmpty)
        XCTAssertTrue(link.unlinkCalls.isEmpty); XCTAssertEqual(vm.refreshCounter, 0)
    }

    @MainActor
    func testRemoveAllDeploysLeavesCursorArtifactsAlone() throws {
        let store = DeployStateStore(fileService: FileService(), appSupportDir: try deletionRoot())
        let skill = Skill(name: "A", directoryName: "a"), link = DeletionTestLinkService()
        let cursor = DeletionTestCursorCompiler(), path = cursor.outputPath(skill: skill, projectPath: nil)
        try store.replaceAll([stateRecord(path: path, platform: .cursor)])
        let result = deletionVM(installed: [.cursor], link: link, cursor: cursor, store: store)
            .removeAllDeploys(skill: skill, projects: [])
        XCTAssertTrue(result.outcomes.isEmpty); XCTAssertTrue(cursor.removeProjectPaths.isEmpty)
        XCTAssertEqual(try store.read().records.map(\.artifactPath), [path])
    }

    @MainActor
    func testRemoveAllDeploysRefusesWhenStateUnreadable() throws {
        let root = try deletionRoot(), fs = FileService(), store = DeployStateStore(fileService: fs, appSupportDir: root)
        try fs.writeFile(at: root + "/deploy-state.json", content: "not json")
        let skill = Skill(name: "A", directoryName: "a"), link = DeletionTestLinkService()
        link.linkedPaths.insert(link.path(skill, .claudeCode, nil))
        let result = deletionVM(installed: [.claudeCode], link: link, store: store)
            .removeAllDeploys(skill: skill, projects: [])
        XCTAssertTrue(result.failures.first?.error?.contains("unreadable") == true)
        XCTAssertTrue(link.unlinkCalls.isEmpty)
        XCTAssertEqual(try fs.readFile(at: root + "/deploy-state.json"), "not json")
    }

    @MainActor
    func testRemoveAllDeploysUnreadableStateWithNoLinksIsNoop() throws {
        let root = try deletionRoot(), fs = FileService(), store = DeployStateStore(fileService: fs, appSupportDir: root)
        try fs.writeFile(at: root + "/deploy-state.json", content: "garbage")
        let vm = deletionVM(installed: [.claudeCode], link: DeletionTestLinkService(), store: store)
        XCTAssertTrue(vm.removeAllDeploys(skill: Skill(name: "A", directoryName: "a"), projects: []).outcomes.isEmpty)
        XCTAssertEqual(try fs.readFile(at: root + "/deploy-state.json"), "garbage")
        XCTAssertEqual(vm.refreshCounter, 0)
    }

    @MainActor
    func testRemoveAllDeploysRefusesWhenStateSchemaIsNewer() throws {
        let root = try deletionRoot(), fs = FileService(), store = DeployStateStore(fileService: fs, appSupportDir: root)
        let bytes = "{\"records\":[],\"schema_version\":2}"
        try fs.writeFile(at: root + "/deploy-state.json", content: bytes)
        let skill = Skill(name: "A", directoryName: "a"), link = DeletionTestLinkService()
        link.linkedPaths.insert(link.path(skill, .claudeCode, nil))
        let result = deletionVM(installed: [.claudeCode], link: link, store: store)
            .removeAllDeploys(skill: skill, projects: [])
        XCTAssertTrue(result.failures.first?.error?.contains("newer schema") == true)
        XCTAssertTrue(link.unlinkCalls.isEmpty)
        XCTAssertEqual(try fs.readFile(at: root + "/deploy-state.json"), bytes)
    }

    @MainActor
    func testRemoveAllDeploysReportsStateWriteFailureAfterArtifactRemoval() throws {
        let root = try deletionRoot(), fs = MemoryDeployFileService()
        let store = DeployStateStore(fileService: fs, appSupportDir: root)
        let skill = Skill(name: "A", directoryName: "a"), link = DeletionTestLinkService()
        let path = link.path(skill, .claudeCode, nil); link.linkedPaths.insert(path)
        try store.replaceAll([stateRecord(path: path)]); fs.failingWrites.insert(root + "/deploy-state.json")
        let result = deletionVM(installed: [.claudeCode], link: link, store: store)
            .removeAllDeploys(skill: skill, projects: [])
        XCTAssertEqual(link.unlinkCalls.count, 1); XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(try store.read().records.map(\.artifactPath), [path])
    }

    @MainActor
    func testRemoveAllDeploysRetryAfterStateWriteFailureDropsRecord() throws {
        let root = try deletionRoot(), fs = MemoryDeployFileService()
        let store = DeployStateStore(fileService: fs, appSupportDir: root)
        let skill = Skill(name: "A", directoryName: "a"), link = DeletionTestLinkService()
        let path = link.path(skill, .claudeCode, nil); link.linkedPaths.insert(path)
        try store.replaceAll([stateRecord(path: path)]); fs.failingWrites.insert(root + "/deploy-state.json")
        let vm = deletionVM(installed: [.claudeCode], link: link, store: store)
        XCTAssertEqual(vm.removeAllDeploys(skill: skill, projects: []).failures.count, 1)
        fs.failingWrites.removeAll()
        XCTAssertEqual(vm.removeAllDeploys(skill: skill, projects: []).successes.count, 1)
        XCTAssertEqual(link.unlinkCalls.count, 1); XCTAssertTrue(try store.read().records.isEmpty)
    }

    @MainActor
    func testRemoveAllDeploysReadsStateExactlyOnce() throws {
        let root = try deletionRoot(), fs = MemoryDeployFileService()
        let store = DeployStateStore(fileService: fs, appSupportDir: root), statePath = root + "/deploy-state.json"
        try store.replaceAll([])
        let skill = Skill(name: "A", directoryName: "a"), link = DeletionTestLinkService()
        let vm = deletionVM(installed: [.claudeCode, .codex], link: link, store: store)
        fs.readCounts.removeAll()
        XCTAssertTrue(vm.removeAllDeploys(skill: skill, projects: []).outcomes.isEmpty)
        XCTAssertEqual(fs.readCounts[statePath], 1)
        let project = Project(name: "P", path: "/p")
        let pairs: [(PlatformTarget, String?)] = [(.claudeCode, nil), (.codex, nil), (.claudeCode, project.path)]
        link.linkedPaths = Set(pairs.map { link.path(skill, $0.0, $0.1) })
        try store.replaceAll(pairs.map { stateRecord(path: link.path(skill, $0.0, $0.1), platform: $0.0) })
        fs.readCounts.removeAll()
        XCTAssertEqual(vm.removeAllDeploys(skill: skill, projects: [project]).successes.count, 3)
        // One up-front read, one per removed record, and one index refresh after the batch.
        XCTAssertEqual(fs.readCounts[statePath], 5)
    }
}
