import SwiftData
import XCTest
@testable import Pensieve

@MainActor
extension AppRuntimePathsTests {
    func assertSyncScanAndRebuild(
        paths: AppRuntimePaths, files: LinkServiceCanonicalDirectoryFileService,
        fixture: GitFailureFixture, context: ModelContext
    ) async throws {
        let git = paths.makeGitService(fileService: files)
        try requireContainedGit([git], files: files)
        let credentials = try XCTUnwrap(paths.makeCredentialStore() as? InMemoryCredentialStore)
        try credentials.store(token: "fixture-sync-token", username: "fixture", forHost: "github.com")
        let remote = fixture.base + "/sync.git"
        _ = try git.runOrThrow(["init", "--bare", remote], in: nil)
        let url = "https://github.com/fixture/sync-\(UUID().uuidString).git"
        let helperRoot = try localSyncTransport(files: files, fixture: fixture, remote: remote)
        let oldExecPath = ProcessInfo.processInfo.environment["GIT_EXEC_PATH"]
        setenv("GIT_EXEC_PATH", helperRoot, 1)
        defer {
            if let oldExecPath { setenv("GIT_EXEC_PATH", oldExecPath, 1) } else { unsetenv("GIT_EXEC_PATH") }
        }
        XCTAssertEqual(try git.runOrThrow(["--exec-path"], in: nil).stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                       helperRoot)
        try git.initRepository(at: paths.storeRoot)
        try git.stageAllAndCommit(at: paths.storeRoot, message: "fixture")
        try git.setRemote(url, at: paths.storeRoot)
        _ = try git.runOrThrow(["-C", paths.storeRoot, "push", "-u", "origin", "main"], in: nil)
        let skillStore = SkillStore(fileService: files, baseDir: paths.skillsDir, storeRoot: paths.skillsDir)
        let slug = try skillStore.createSkill(name: "Runtime", description: "Sync fixture", body: "local sync body")
        context.insert(Skill(name: "Runtime", skillDescription: "Sync fixture", directoryName: slug))
        try context.save()
        try assertTemporaryDeploymentFactories(paths: paths, files: files, context: context)
        let coordinator = SyncCoordinator(modelContainer: context.container)
        var machineWrites: [String] = []
        files.beforeFileWrite = { if $0.contains(".machine-state-") { machineWrites.append($0) } }
        defer { files.beforeFileWrite = nil }
        await paths.configureCoordinator(coordinator, defaults: try isolatedDefaults(), fileService: files)
        let result = await coordinator.runCycle()
        guard case .synced = result else { return XCTFail("Temporary runtime cycle failed: \(result)") }
        XCTAssertEqual(machineWrites.count, 1, "Coordinator machine-state writes must use its supplied file service")
        let states = paths.makeMachineStateService(defaults: try isolatedDefaults(), fileService: files)
            .readAll(fromRoot: paths.storeRoot)
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states.first?.agents, [])
        XCTAssertTrue(try git.runOrThrow(["--git-dir", remote, "show", "HEAD:skills/runtime/SKILL.md"], in: nil)
            .stdout.contains("local sync body"))
        XCTAssertTrue(files.isExecutableFile(at: paths.gitAskpassHelperPath))
        XCTAssertTrue(try files.readFile(at: paths.appSupportDir + "/daemon.log").contains("synced"))
        let scanPath = try XCTUnwrap(paths.deployPaths.userSkillsRoot(for: .claudeCode)) + "/scanned/SKILL.md"
        try files.writeFile(at: scanPath, content: "---\nname: Scanned\ndescription: Scan fixture\n---\nscan body\n")
        let found = paths.makeImportScanner(fileService: files).scan()
        XCTAssertTrue(found.contains { $0.sourcePath == scanPath && $0.name == "Scanned" })
        let rebuilt = paths.makeStoreRebuildService(fileService: files).rebuild(fromRoot: paths.storeRoot, context: context)
        XCTAssertFalse(rebuilt.storeUnreadable)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Skill>()).contains { $0.directoryName == slug })
    }

    private func assertTemporaryDeploymentFactories(
        paths: AppRuntimePaths, files: FileServiceProtocol, context: ModelContext
    ) throws {
        try files.createDirectory(at: paths.homeDirectory + "/.claude")
        XCTAssertFalse(paths.makeAgentDetection().isInstalled(.claudeCode))
        XCTAssertEqual(paths.makeAgentDetection().installedPlatforms(), [])
        let skill = try XCTUnwrap(context.fetch(FetchDescriptor<Skill>()).first { $0.directoryName == "runtime" })
        let platform = paths.makePlatformViewModel()
        var ownedPaths: [String] = []
        var danglingPaths: [String] = []
        for target: PlatformTarget in [.claudeCode, .hermes] {
            let category = target == .hermes ? "/" + PathConstants.hermesDefaultCategory : ""
            let root = paths.appSupportDir + "/agent-skills/" + target.rawValue + category
            XCTAssertEqual(paths.deployPaths.userSkillsRoot(for: target), root)
            let owned = root + "/runtime"
            XCTAssertEqual(platform.artifactPath(skill: skill, platform: target, target: .userWide), owned)
            XCTAssertEqual(platform.linkService.targetPath(skill: skill, platform: target, projectPath: nil),
                           paths.skillsDir + "/runtime")
            try files.createSymlink(at: owned, pointingTo: paths.skillsDir + "/runtime")
            ownedPaths.append(owned)
            let dangling = root + "/gone"
            try files.createSymlink(at: dangling, pointingTo: paths.skillsDir + "/gone")
            danglingPaths.append(dangling)
        }
        paths.makeLaunchBackfill()(context)
        let state = DeployStateStore(fileService: files, appSupportDir: paths.appSupportDir)
        let artifacts = try state.read().records.map(\.artifactPath)
        XCTAssertEqual(artifacts.count, ownedPaths.count)
        XCTAssertEqual(Set(artifacts), Set(ownedPaths))
        let intent = AppRuntime.makeLaunchIntentReconciler(platformVM: platform, paths: paths)
        paths.makeConvergence(container: context.container, platformVM: platform, intentReconciler: intent)
            .run(after: .synced(pushed: false, warnings: [], completedAt: Date(), headAdvanced: false))
        for dangling in danglingPaths {
            XCTAssertFalse(files.isSymlink(at: dangling), "App convergence must prune its sandboxed agent roots")
        }
        for owned in ownedPaths { XCTAssertTrue(files.isSymlink(at: owned)) }
    }

    private func localSyncTransport(
        files: FileServiceProtocol, fixture: GitFailureFixture, remote: String
    ) throws -> String {
        let helperRoot = fixture.base + "/git-helpers"
        try files.writeExecutableFile(at: helperRoot + "/git-remote-https", content: """
            #!/usr/bin/env python3
            import os, sys
            for line in sys.stdin:
                command = line.strip()
                if command == 'capabilities':
                    print('connect\\n', flush=True)
                elif command.startswith('connect '):
                    print('', flush=True)
                    operation = command.split()[1].removeprefix('git-')
                    os.execv('/usr/bin/git', ['git', operation, '\(remote)'])
                elif command.startswith('option '):
                    print('unsupported', flush=True)
            """ + "\n")
        return helperRoot
    }

}
