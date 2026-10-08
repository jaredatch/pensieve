import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
struct WaitingRemovalHarness {
    let base: ProjectFolderCallerHarness
    let mapped: LinkServiceCanonicalDirectoryFileService
    let vm: PlatformViewModel
    let library: SkillLibraryViewModel

    init(platforms: [PlatformTarget] = [.codex], persistent: Bool = false) throws {
        let base = try ProjectFolderCallerHarness(installed: platforms, persistent: persistent)
        self.base = base
        let mappings = [(TestPaths.skillsDir, base.root + "/store/skills"),
                        (TestPaths.deployPaths.cursorUserRulesDirectory, base.root + "/user/rules")]
            + PlatformTarget.allCases.compactMap { platform in
                TestPaths.deployPaths.userSkillsRoot(for: platform).map { ($0, base.root + "/user/" + platform.rawValue) }
            }
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
            skillStore: SkillStore(fileService: mapped, baseDir: TestPaths.skillsDir),
            fileService: mapped, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir),
            manifestService: ManifestService(fileService: base.files), manifestRoot: base.root + "/store",
            notifier: {}
        )
        try base.files.writeFile(at: base.root + "/support/machine-id", content: ProjectIntentHarness.localID + "\n")
    }

    var storePath: String { base.root + "/support/waiting-removals.json" }
    var offlinePath: String { base.root + "/offline" }

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
            platformVM: vm, localMachineID: ProjectIntentHarness.localID, context: base.context)
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
