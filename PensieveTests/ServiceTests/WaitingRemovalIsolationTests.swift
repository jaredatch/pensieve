import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class WaitingRemovalIsolationTests: XCTestCase {
    func testWaitingSurvivesBackfillHealAndStaysOutOfPublishedAndDisplayedDeployments() throws {
        let h = try WaitingRemovalHarness()
        defer { h.base.cleanup() }
        try h.deploy([.codex])
        try h.hideFolder()
        XCTAssertTrue(h.deleteSkill())
        let entry = try XCTUnwrap(h.vm.waitingRemovalStore.read().first)
        let bytes = try h.base.files.readData(at: h.storePath)
        try h.base.files.writeFile(at: h.base.root + "/support/deploy-state.json", content: "corrupt derived state")
        DeployStateBackfill(fileService: h.mapped, store: h.base.deployState,
            paths: DeployStateBackfillPaths(pensieveSkillsDir: Constants.pensieveSkillsDir,
                cursorUserRulesDir: Constants.cursorUserRulesDir)).backfill(context: h.base.context)
        XCTAssertTrue(try h.base.deployState.read().records.isEmpty)
        XCTAssertEqual(try h.base.files.readData(at: h.storePath), bytes)
        try h.base.deployState.replaceAll([])
        h.vm.refreshDeployIndex()
        XCTAssertFalse(h.vm.deployIndex.isDeployed(slug: entry.slug))
        XCTAssertTrue(h.vm.deployIndex.records(for: entry.slug).isEmpty)
        let manifest = ManifestService(fileService: h.base.files)
        try manifest.write(try manifest.snapshot(from: h.base.context), toRoot: h.base.root + "/store")
        let machine = MachineStateService(fileService: h.mapped,
            agentDetection: DeployStubDetection(installed: [.codex]), deployState: { try h.base.deployState.read() })
        let observation = try machine.compose(machineID: ProjectIntentHarness.localID,
            context: h.base.context, publishedAt: Date())
        XCTAssertTrue(observation.userDeploys.isEmpty)
        XCTAssertTrue(observation.projectDeploys.isEmpty)
        try machine.write(observation, toRoot: h.base.root + "/store")
        for file in try descendants(h.base.root + "/store", files: h.base.files) {
            XCTAssertFalse(file.hasSuffix("/waiting-removals.json"))
            let content = try h.base.files.readFile(at: file)
            XCTAssertFalse(content.contains(entry.id.uuidString), file)
            XCTAssertFalse(content.contains(entry.artifactPath), file)
        }
        let result = DaemonCLI.execute(["deployed", "--app-support", h.base.root + "/support"],
            appSupport: h.base.root + "/unused", readFile: { try? h.base.files.readData(at: $0) },
            runCycle: { XCTFail("Listing must not run a cycle"); return .synced(changed: false) }, now: Date.init)
        XCTAssertEqual(result.stdout, "no deployments recorded\n")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try h.base.files.readData(at: h.storePath), bytes)
    }

    func testSuccessfulDaemonPassPrunesUserLinkButNeverRunsReadyProjectWaitingRemoval() throws {
        let h = try WaitingRemovalHarness()
        defer { h.base.cleanup() }
        try h.deploy([.codex])
        try h.hideFolder()
        XCTAssertTrue(h.deleteSkill())
        try h.restoreFolder()
        let bytes = try h.base.files.readData(at: h.storePath)
        let userDirectory = h.base.root + "/daemon-skills"
        let userLink = userDirectory + "/dangling"
        try h.base.files.createDirectory(at: userDirectory)
        try h.base.files.createSymlink(at: userLink, pointingTo: h.base.root + "/store/skills/dangling")
        let reconciler = DeployReconciler(fileService: h.base.files, deployState: h.base.deployState,
            pensieveSkillsDir: h.base.root + "/store/skills",
            agentSkillDirs: [.init(platform: .claudeCode, path: userDirectory)],
            cursorRulesDir: h.base.root + "/daemon-rules")
        let daemon = SyncDaemon(root: h.base.root + "/store", appSupport: h.base.root + "/support",
            git: WaitingDaemonGit(), hasLocalBranches: { _ in true }, credentials: InMemoryCredentialStore(),
            reconciler: reconciler, now: Date.init)
        XCTAssertEqual(daemon.runOnce(), .synced(changed: false))
        XCTAssertFalse(h.base.files.isSymlink(at: userLink), "The daemon's real removal pass must run")
        XCTAssertTrue(h.base.files.isSymlink(at: h.base.artifact(.codex)))
        XCTAssertEqual(try h.base.files.readData(at: h.storePath), bytes)
        XCTAssertEqual(try h.vm.waitingRemovalStore.read().count, 1)
    }

    private func descendants(_ path: String, files: FileService) throws -> [String] {
        var result: [String] = []
        for name in try files.listDirectory(at: path) {
            let child = path + "/" + name
            if files.directoryExists(at: child) { result += try descendants(child, files: files) } else {
                result.append(child)
            }
        }
        return result
    }
}

private struct WaitingDaemonGit: FastForwardGitService {
    func remoteURL(at path: String) throws -> String? { "https://example.com/store.git" }
    func isWorktreeClean(at path: String) -> Bool { true }
    func fetch(at path: String, credential: GitCredential?) throws {}
    func fastForwardOnly(at path: String, credential: GitCredential?) throws -> FastForwardResult { .upToDate }
}
