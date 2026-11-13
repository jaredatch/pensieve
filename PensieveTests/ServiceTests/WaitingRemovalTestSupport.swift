import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class WaitingRemovalHarness {
    let base: ProjectFolderCallerHarness
    let mapped: LinkServiceCanonicalDirectoryFileService
    let vm: PlatformViewModel
    let library: SkillLibraryViewModel
    private var additionalSaveQueues: [(name: String, saves: ManifestSaveModel)] = []

    init(platforms: [PlatformTarget] = [.codex], persistent: Bool = false) throws {
        let base = try ProjectFolderCallerHarness(installed: platforms, persistent: persistent)
        self.base = base
        // Map the whole hierarchy: containment now resolves each agent directory's parent too.
        let mappings = [(TestPaths.storeRoot, base.root + "/store"),
                        (TestPaths.homeDirectory, base.root + "/home")]
        mapped = LinkServiceCanonicalDirectoryFileService(wrapped: base.files,
            pathMappings: mappings, physicalSandbox: base.root)
        vm = PlatformViewModel(
            fileService: mapped,
            linkService: TestPaths.linkService(fileService: mapped),
            cursorCompiler: TestPaths.cursorCompiler(fileService: mapped),
            agentDetection: DeployStubDetection(installed: platforms),
            deployStateStore: base.deployState, skillsDirectory: TestPaths.skillsDir,
            waitingRemovalStore: WaitingRemovalStore(fileService: mapped, appSupportDir: base.root + "/support")
        )
        library = SkillLibraryViewModel(
            skillStore: SkillStore(fileService: mapped, baseDir: TestPaths.skillsDir, storeRoot: TestPaths.storeRoot),
            fileService: mapped, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir),
            manifestRoot: base.root + "/store",
            notifier: {},
            manifestSaves: ManifestSaveModel(manifest: ManifestService(fileService: base.files), root: base.root + "/store",
                lockPath: base.root + "/store" + ".sync.lock", files: mapped))
        try base.files.writeFile(at: base.root + "/support/machine-id", content: ProjectIntentHarness.localID + "\n")
    }

    var storePath: String { base.root + "/support/waiting-removals.json" }
    var offlinePath: String { base.root + "/offline" }

    func trackSaveQueue(_ saves: ManifestSaveModel, named name: String) {
        guard saves !== library.manifestSaves,
              !additionalSaveQueues.contains(where: { $0.saves === saves }) else { return }
        additionalSaveQueues.append((name, saves))
    }

    func tearDown(after owner: XCTestCase, file: StaticString = #filePath, line: UInt = #line) {
        // Called from defer: disarm before returning the main actor to the queued save.
        clearHooks(on: mapped)
        clearHooks(on: base.mapped)
        let testName = owner.name
        owner.addTeardownBlock { @MainActor in
            await self.tearDown(testName: testName, file: file, line: line)
        }
    }

    /// Disarm both doubles before giving save workers a turn. Join the shared queue and every
    /// registered queue before removing their sandbox. A bounded failure names its owner and
    /// leaves the sandbox intact: saves cannot be stopped once they are waiting in flock.
    @discardableResult
    func tearDown(testName: String, timeout: Duration = .seconds(TestWait.timeoutSeconds),
                  file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        clearHooks(on: mapped)
        clearHooks(on: base.mapped)
        let queues = (library.manifestSaves.map { [(name: "library.manifestSaves", saves: $0)] } ?? [])
            + additionalSaveQueues
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while queues.contains(where: { $0.saves.pendingCount > 0 }), clock.now < deadline, !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
        }
        let unfinished = queues.filter { $0.saves.pendingCount > 0 }
        guard unfinished.isEmpty else {
            for queue in unfinished {
                XCTFail("Unfinished manifest save: \(queue.name) in \(testName); "
                    + "pending=\(queue.saves.pendingCount), lock=\(queue.saves.lockPath)", file: file, line: line)
            }
            return false
        }
        base.cleanup()
        return true
    }

    private func clearHooks(on double: LinkServiceCanonicalDirectoryFileService) {
        double.beforeDirectoryCreation = nil
        double.beforeArtifactCreation = nil
        double.beforeArtifactDeletion = nil
        double.beforeProjectProbe = nil
        double.beforeRuleRead = nil
        double.beforeEntryTypeProbe = nil
        double.beforeDeployStateRead = nil
        double.beforeDeployStateWrite = nil
        double.beforeFileWrite = nil
        double.beforeSymlinkRead = nil
        double.beforePathResolution = nil
    }

    func deploy(_ platforms: [PlatformTarget]) throws {
        try base.files.createDirectory(at: base.project.path)
        try recordProjectIdentity()
        for platform in platforms { try base.addIntent(platform: platform) }
        XCTAssertFalse(base.intent.reconcile(context: base.context).hasFailures)
    }

    func recordProjectIdentity() throws {
        guard let key = base.project.identityKey else { return }
        try base.files.writeFile(at: base.project.path + "/.git/config",
            content: "[remote \"origin\"]\nurl = https://\(key).git\n")
    }

    func hideFolder() throws {
        try recordProjectIdentity()
        try base.files.replaceItem(at: offlinePath, with: base.project.path)
    }
    func restoreFolder() throws { try base.files.replaceItem(at: base.project.path, with: offlinePath) }

    @discardableResult
    func deleteSkill() -> Bool {
        SkillDeletionFlow.delete(skill: base.skill, library: library, platformVM: vm,
            projects: [base.project, base.otherProject], context: base.context)
    }

    func removeProject() -> BatchResult {
        removeRegisteredProject(base.project, reconciler: base.category,
            manifestService: ManifestService(fileService: base.files), manifestRoot: base.root + "/store",
            platformVM: vm, localMachineID: ProjectIntentHarness.localID, context: base.context,
            lockPath: base.root + "/store" + ".sync.lock")
    }

    func converge() -> [String] {
        var audit: [String] = []
        base.convergence { _, detail in audit.append(detail) }.runAfterLaunchIngest()
        return audit
    }

    func entry(platform: PlatformTarget = .codex, source: String = "old") -> WaitingRemoval {
        vm.waitingRemoval(skill: base.skill, platform: platform, project: base.project, source: source)
    }
}

struct WaitingDesiredReadFault: ReconcilerStateFetching {
    let failing: String
    private let real = ReconcilerStateFetcher()

    private func check(_ name: String) throws {
        if name == failing { throw CocoaError(.fileReadNoPermission) }
    }

    func projects(context: ModelContext) throws -> [Project] {
        try check("projects"); return try real.projects(context: context)
    }
    func skills(context: ModelContext) throws -> [Skill] {
        try check("skills"); return try real.skills(context: context)
    }
    func deployIntents(context: ModelContext) throws -> [MachineDeployIntent] {
        try check("intents"); return try real.deployIntents(context: context)
    }
    func categories(context: ModelContext) throws -> [Pensieve.Category] {
        try check("categories"); return try real.categories(context: context)
    }
    func intentAssignments(context: ModelContext) throws -> [IntentAssignment] {
        try real.intentAssignments(context: context)
    }
    func categoryAssignments(context: ModelContext) throws -> [SkillProjectAssignment] {
        try real.categoryAssignments(context: context)
    }
}
