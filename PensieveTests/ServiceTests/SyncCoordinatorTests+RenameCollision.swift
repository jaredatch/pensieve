import SwiftData
import XCTest
@testable import Pensieve

@MainActor
extension SyncCoordinatorTests {
    func testRealPullOfAnotherMacsRenamedSkillConflictsWithoutLosingEitherCopy() async throws {
        let h = try makeRemoteHarness()
        let files = FileService(), manifest = ManifestService()
        let support = h.clone + "/../rename-support"
        let lockPath = support + "/sync.lock"
        let context = h.container.mainContext
        let skill = Skill(name: "Alpha", tags: ["own"], scope: .project, directoryName: "alpha")
        skill.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(skill)
        let store = SkillStore(fileService: files, baseDir: h.clone + "/skills", storeRoot: h.clone)
        _ = try store.createSkill(name: "Alpha", description: "Local", body: "This Mac's text.")
        try context.save()
        try manifest.write(try manifest.snapshot(from: context), toRoot: h.clone)
        XCTAssertTrue(try NativeTestWork.run { try h.git.stageAllAndCommit(at: h.clone, message: "local skill") })
        try NativeTestWork.run { try h.git.push(at: h.clone, credential: nil) }
        let (peerBody, peerRecord) = try publishRenamePeer(h, files: files, manifest: manifest)
        StoreIngestState.shared(for: h.container).seedHead(GitHeadStamp().read(root: h.clone))
        let saves = ManifestSaveModel(manifest: manifest, root: h.clone, lockPath: lockPath)
        let library = SkillLibraryViewModel(skillStore: store, fileService: files,
            fileWatchService: RecordingWatcher(), manifestRoot: h.clone,
            notifier: SyncStateNotifier.suppressed, manifestSaves: saves)
        let platform = renameCollisionPlatform(store: store, support: support, files: files)
        // Configure before the rename: the same main-actor turn must hand the lock to sync.
        var transferred: SyncLock?
        var calls = 0
        let engine = SyncEngine(gitService: h.allowlistedGit, manifestService: manifest,
            storeRebuildService: StoreRebuildService(), fileService: files, lockPath: lockPath,
            lockProvider: { _ in calls += 1; return transferred })
        let coordinator = await configuredCoordinator(container: h.container, engine: engine,
            git: h.allowlistedGit, root: h.clone)
        XCTAssertTrue(SkillRenameFlow.rename(skill: skill, to: "Zulu", library: library,
            platformVM: platform, projects: [], context: context))
        transferred = try XCTUnwrap(SyncLock.tryAcquire(at: lockPath))
        defer { transferred?.release() }
        XCTAssertEqual(saves.pendingCount, 1)
        XCTAssertTrue(try manifest.read(fromRoot: h.clone).skills.contains { $0.slug == "alpha" })
        let result = await coordinator.runCycle()
        await saves.waitUntilIdle()
        XCTAssertEqual(calls, 1)
        guard case .conflicted(let paths) = result else { return XCTFail("Expected skill conflict, got \(result)") }
        XCTAssertTrue(paths.contains("skills/zulu/SKILL.md"))
        try assertRemoteRenameCopy(h, body: peerBody, record: peerRecord)
        XCTAssertTrue(try files.readFile(at: h.clone + "/skills/zulu/SKILL.md").contains("This Mac's text."))
        XCTAssertTrue(library.editorBody(for: skill).contains("This Mac's text."))
        XCTAssertEqual(skill.tags, ["own"])
        XCTAssertEqual(skill.scope, .project)
        let local = try XCTUnwrap(manifest.read(fromRoot: h.clone).skills.first { $0.slug == "zulu" })
        XCTAssertEqual(local.tags, ["own"])
        XCTAssertEqual(local.scope, .project)
        XCTAssertNil(library.error)
    }

    private func assertRemoteRenameCopy(_ h: RemoteHarness, body: Data, record: Data) throws {
        let remoteBody = try NativeTestWork.run {
            h.git.show(sha: "HEAD", path: "skills/zulu/SKILL.md", at: h.remotePath)
        }
        let remoteRecord = try NativeTestWork.run {
            h.git.show(sha: "HEAD", path: "manifest/skills/zulu.yaml", at: h.remotePath)
        }
        XCTAssertEqual(remoteBody?.data(using: .utf8), body)
        XCTAssertEqual(remoteRecord?.data(using: .utf8), record)
    }

    private func publishRenamePeer(_ h: RemoteHarness, files: FileService, manifest: ManifestService) throws -> (Data, Data) {
        let peer = h.clone + "/../rename-peer"
        try NativeTestWork.run { try h.git.clone(remote: h.remote, into: peer, credential: nil) }
        let peerStore = SkillStore(fileService: files, baseDir: peer + "/skills", storeRoot: peer)
        _ = try peerStore.createSkill(name: "Zulu", description: "Remote", body: "Other Mac's text.")
        var remote = try manifest.read(fromRoot: peer)
        var overlay = try XCTUnwrap(remote.skills.first)
        overlay.slug = "zulu"; overlay.tags = ["peer"]; overlay.scope = .user
        overlay.createdAt = Date(timeIntervalSince1970: 1_650_000_000)
        remote.skills.append(overlay)
        try manifest.write(remote, toRoot: peer)
        let peerBody = try files.readData(at: peer + "/skills/zulu/SKILL.md")
        let peerRecord = try files.readData(at: peer + "/manifest/skills/zulu.yaml")
        XCTAssertTrue(try NativeTestWork.run { try h.git.stageAllAndCommit(at: peer, message: "peer skill") })
        try NativeTestWork.run { try h.git.push(at: peer, credential: nil) }
        return (peerBody, peerRecord)
    }

    private func renameCollisionPlatform(store: SkillStore, support: String, files: FileService) -> PlatformViewModel {
        let paths = DeployPaths(skillsDirectory: store.baseDir,
            userSkillsDirectories: [.claudeCode: support + "/agent"], cursorUserRulesDirectory: support + "/rules")
        return PlatformViewModel(fileService: files,
            linkService: LinkService(fileService: files, paths: paths),
            cursorCompiler: CursorCompiler(fileService: files, skillStore: store,
                userRulesDirectory: paths.cursorUserRulesDirectory),
            agentDetection: DeletionTestDetection(installed: []),
            deployStateStore: DeployStateStore(fileService: files, appSupportDir: support), skillsDirectory: store.baseDir)
    }

}
