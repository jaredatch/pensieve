import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ManifestRenameTests: XCTestCase {
    private let files = FileService()
    private let machineA = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let machineB = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"

    private func snapshot() -> ManifestSnapshot {
        var origin = InstalledOrigin.empty
        origin.repo = "owner/repo"; origin.path = "skills/alpha"; origin.ref = "main"
        origin.installedCommit = "abc"; origin.installedTree = "def"; origin.contentHash = "hash"
        let overlay = SkillOverlay(slug: "alpha", createdAt: Date(timeIntervalSince1970: 123456),
            scope: .project, tags: ["one", "two"], cursor: CursorAdapterConfig(), agents: [], origin: .installed(origin))
        var other = overlay; other.slug = "other"; other.tags = ["untouched"]
        return ManifestSnapshot(schemaVersion: 5,
            categories: [CategoryRecord(name: "Tools", projectKeys: [], skillSlugs: ["alpha", "other"])],
            projects: [], skills: [overlay, other], deployIntents: [
                DeployIntentRecord(machineID: machineA, skillSlug: "alpha", platformRaw: "claudeCode", projectKey: nil),
                DeployIntentRecord(machineID: machineA, skillSlug: "alpha", platformRaw: "codex", projectKey: nil),
                DeployIntentRecord(machineID: machineA, skillSlug: "alpha", platformRaw: "cursor", projectKey: "github.com/a/b"),
                DeployIntentRecord(machineID: machineB, skillSlug: "alpha", platformRaw: "claudeCode", projectKey: nil)])
    }

    func testRenameMovesOverlayIntentsAndCategoryMembership() async throws {
        let root = TestTemporaryDirectory.path + "ManifestRename-" + UUID().uuidString
        defer { try? files.deleteDirectory(at: root) }
        let manifest = ManifestService(fileService: files)
        let original = snapshot()
        try manifest.write(original, toRoot: root)
        let otherBytes = try files.readData(at: root + "/manifest/skills/other.yaml")
        let context = ModelContext(try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true)))
        let saves = ManifestSaveModel(manifest: manifest, root: root, lockPath: root + "/sync.lock", files: files)
        var failure: Error?
        saves.submit(.renameSkill("alpha", "zulu"), context: context) { failure = $0 }
        await saves.waitUntilIdle()
        XCTAssertNil(failure)
        let result = try manifest.read(fromRoot: root)
        var expected = original.skills[0]; expected.slug = "zulu"
        XCTAssertEqual(result.skills.first { $0.slug == "zulu" }, expected)
        XCTAssertFalse(result.skills.contains { $0.slug == "alpha" })
        XCTAssertEqual(result.deployIntents, original.deployIntents.map {
            var intent = $0; intent.skillSlug = "zulu"; return intent
        }.sorted { ($0.machineID, $0.projectKey ?? "", $0.platformRaw) < ($1.machineID, $1.projectKey ?? "", $1.platformRaw) })
        XCTAssertEqual(result.categories[0].skillSlugs, ["other", "zulu"])
        XCTAssertEqual(try files.readData(at: root + "/manifest/skills/other.yaml"), otherBytes)
        XCTAssertFalse(files.fileExists(at: root + "/manifest/skills/alpha.yaml"))
        for machine in [machineA, machineB] {
            XCTAssertTrue(files.fileExists(at: root + "/manifest/deploys/" + machine + "/zulu.yaml"))
            XCTAssertFalse(files.fileExists(at: root + "/manifest/deploys/" + machine + "/alpha.yaml"))
        }
        let change = ManifestChange.renameSkill("alpha", "zulu")
        var absent = ManifestSnapshot(schemaVersion: 5, categories: [], projects: [], skills: [])
        let empty = absent
        XCTAssertFalse(change.apply(to: &absent)); XCTAssertEqual(absent, empty)
        var retry = result
        XCTAssertTrue(change.apply(to: &retry)); XCTAssertEqual(retry, result)
        var collision = original; collision.skills.append(expected)
        XCTAssertThrowsError(try change.validate(in: collision))
        for new in [String(repeating: "a", count: 65), "bad/name"] {
            XCTAssertThrowsError(try ManifestChange.renameSkill("alpha", new).validate(in: original))
        }
    }

    func testOtherMacConvergesToRenamedSkill() throws {
        let root = TestTemporaryDirectory.path + "OtherMacRename-" + UUID().uuidString
        defer { try? files.deleteDirectory(at: root) }
        let skills = root + "/skills", agent = root + "/agent", support = root + "/support"
        let store = SkillStore(fileService: files, baseDir: skills, storeRoot: root)
        _ = try store.createSkill(name: "Beta Two", description: "job", body: "body")
        var original = snapshot(); original.skills.removeAll { $0.slug == "other" }
        original.deployIntents = [original.deployIntents[0]]
        original.categories[0].skillSlugs = ["alpha"]
        let overlay = original.skills[0]
        XCTAssertTrue(ManifestChange.renameSkill("alpha", "beta-two").apply(to: &original))
        let manifest = ManifestService(fileService: files)
        try manifest.write(original, toRoot: root)
        let context = ModelContext(try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true)))
        let old = Skill(name: "alpha", directoryName: "alpha")
        context.insert(old); context.insert(IntentAssignment(skillID: old.id, platformRaw: "claudeCode"))
        try context.save()
        try files.createSymlink(at: agent + "/alpha", pointingTo: skills + "/alpha")
        let state = DeployStateStore(fileService: files, appSupportDir: support)
        try state.upsert(DeployStateRecord(slug: "alpha", platform: "claudeCode", scope: "user",
            projectIdentityKey: nil, artifactPath: agent + "/alpha", recordedAt: "2026-01-01T00:00:00Z"))
        try files.writeFile(at: support + "/machine-id", content: machineA)
        let paths = DeployPaths(skillsDirectory: skills, userSkillsDirectories: [.claudeCode: agent],
            cursorUserRulesDirectory: root + "/cursor")
        let platform = PlatformViewModel(fileService: files, linkService: LinkService(fileService: files, paths: paths),
            cursorCompiler: CursorCompiler(fileService: files, skillStore: store, userRulesDirectory: root + "/cursor"),
            agentDetection: DeletionTestDetection(installed: [.claudeCode]), deployStateStore: state, skillsDirectory: skills)
        _ = StoreRebuildService(fileService: files, manifestService: manifest).rebuild(fromRoot: root, context: context)
        let convergence = PostSyncConvergence(root: root,
            deployReconciler: DeployReconciler(fileService: files, deployState: state, pensieveSkillsDir: skills,
                agentSkillDirs: [.init(platform: .claudeCode, path: agent)], cursorRulesDir: root + "/cursor"),
            contextFactory: { ModelContext(context.container) }, categoryReconciler: CategoryReconciler(platformVM: platform),
            intentReconciler: IntentReconciler(platformVM: platform,
                machineIdentity: MachineIdentity(fileService: files, appSupportDir: support)), auditLog: { _, _ in })
        convergence.runAfterLaunchIngest()
        let fresh = ModelContext(context.container)
        let rows = try fresh.fetch(FetchDescriptor<Skill>())
        XCTAssertEqual(rows.count, 1)
        let renamed = try XCTUnwrap(rows.first)
        XCTAssertEqual(renamed.directoryName, "beta-two"); XCTAssertNotEqual(renamed.id, old.id)
        XCTAssertEqual(renamed.tags, overlay.tags); XCTAssertEqual(renamed.scope, overlay.scope)
        XCTAssertEqual(renamed.createdAt, overlay.createdAt)
        XCTAssertFalse(files.isSymlink(at: agent + "/alpha"))
        XCTAssertEqual(try files.symlinkTarget(at: agent + "/beta-two"), skills + "/beta-two")
        XCTAssertEqual(try state.read().records.map(\.slug), ["beta-two"])
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Pensieve.Category>()).first?.skillSlugs, ["beta-two"])
    }
}
