import SwiftData
import XCTest
@testable import Pensieve

/// The observable deploy index on `PlatformViewModel` (PLAN-29): loaded at init, refreshed after every
/// write the view model makes, `.unavailable` when the ledger cannot be read. Its own file because
/// `PlatformViewModelTests.swift` sits at the strict lint file-length limit; the fakes come from
/// `DeletionTestSupport.swift`, and the store is the real one at a temp root.
@MainActor
final class PlatformViewModelDeployIndexTests: XCTestCase {
    func testDeployIndexLoadsAtInitAndRefreshesOnRemove() throws {
        let root = try tempRoot()
        let store = DeployStateStore(fileService: FileService(), appSupportDir: root)
        let skill = Skill(name: "Alpha", directoryName: "alpha")
        let link = DeletionTestLinkService()
        let path = link.path(skill, .claudeCode, nil)
        link.linkedPaths.insert(path)
        try store.replaceAll([record(slug: "alpha", path: path)])

        let vm = makeVM(link: link, store: store)
        XCTAssertTrue(vm.deployIndex.available)
        XCTAssertTrue(vm.deployIndex.isDeployed(slug: "alpha"))
        XCTAssertEqual(vm.deployIndex.summary(for: "alpha"), "Claude Code · This Mac")

        XCTAssertEqual(vm.removeAllDeploys(skill: skill, projects: [], localDeployHistory: { _ in [] }).batch.successes.count, 1)
        XCTAssertTrue(vm.deployIndex.available)
        XCTAssertFalse(vm.deployIndex.isDeployed(slug: "alpha"))
    }

    func testDeployIndexUnavailableWhenStateUnreadable() throws {
        let root = try tempRoot()
        try "{not json".write(toFile: root + "/deploy-state.json", atomically: true, encoding: .utf8)
        let store = DeployStateStore(fileService: FileService(), appSupportDir: root)

        let vm = makeVM(link: DeletionTestLinkService(), store: store)
        XCTAssertEqual(vm.deployIndex, .unavailable)
        XCTAssertEqual(vm.deployIndex.summary(for: "anything"), "Deploy state unavailable")

        try store.replaceAll([])
        vm.refreshDeployIndex()
        XCTAssertEqual(vm.deployIndex, .empty)
    }

    func testDeployIndexRefreshesAfterDeployAndBatchRemove() throws {
        let context = try makeContext()
        let skill = Skill(name: "Idx", directoryName: "idx")
        context.insert(skill)
        let store = DeployStateStore(fileService: FileService(), appSupportDir: try tempRoot())
        let vm = makeVM(link: DeletionTestLinkService(), store: store)
        XCTAssertFalse(vm.deployIndex.isDeployed(slug: "idx"))

        vm.deploy(skill: skill, platform: .claudeCode, target: .userWide, context: context)
        XCTAssertEqual(vm.deployIndex.summary(for: "idx"), "Claude Code · This Mac")
        XCTAssertEqual(vm.removeOwnedBatch(
            pairs: DeployRemovalPair.expand(skills: [skill], platforms: [.claudeCode]),
            target: .userWide).successes.count, 1)
        XCTAssertFalse(vm.deployIndex.isDeployed(slug: "idx"))

        XCTAssertEqual(vm.deployBatch(skills: [skill], platforms: [.claudeCode], context: context).successes.count, 1)
        XCTAssertTrue(vm.deployIndex.isDeployed(slug: "idx"))

        vm.remove(skill: skill, platform: .claudeCode, target: .userWide)
        XCTAssertFalse(vm.deployIndex.isDeployed(slug: "idx"))
    }

    // MARK: - Fixtures

    private func makeVM(link: DeletionTestLinkService, store: DeployStateStore) -> PlatformViewModel {
        PlatformViewModel(
            fileService: RegularLeafFileService(), linkService: link, cursorCompiler: DeletionTestCursorCompiler(),
            agentDetection: DeletionTestDetection(installed: [.claudeCode]), deployStateStore: store
        )
    }

    /// A no-op file service whose canonical SKILL.md reads as a regular, non-symlinked file, so
    /// `deployOne`'s C7 and leaf guards admit the skill (the same shape `PlatformViewModelTests`'
    /// `CleanFileService` gives the deploy tests). The real store above does the ledger IO itself.
    private struct RegularLeafFileService: FileServiceProtocol {
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

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self, DeployRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func tempRoot() throws -> String {
        let root = NSTemporaryDirectory() + "PlatformDeployIndex-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        return root
    }

    private func record(slug: String, path: String) -> DeployStateRecord {
        DeployStateRecord(
            slug: slug, platform: PlatformTarget.claudeCode.rawValue, scope: "user",
            projectIdentityKey: nil, artifactPath: path, recordedAt: "2026-09-07T00:00:00Z"
        )
    }
}
