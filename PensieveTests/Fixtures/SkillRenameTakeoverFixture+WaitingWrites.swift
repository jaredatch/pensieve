import SwiftData
import XCTest
@testable import Pensieve

@MainActor
extension SkillRenameTakeoverFixture {
    func waitingWriteDeployments() -> DeployMutationService {
        let identity = MachineIdentity(fileService: files,
            appSupportDir: (lockPath as NSString).deletingLastPathComponent)
        let dependencies = DeployIntentDependencies.live(identity: identity,
            stateService: InertMachineStateService(), root: root, lockPath: lockPath,
            notifier: SyncStateNotifier.suppressed, reconcile: { [platform] context in
                IntentReconciler(platformVM: platform, machineIdentity: identity).reconcile(context: context)
            })
        return DeployMutationService(platformVM: platform, dependencies: dependencies)
    }

    func waitingWriteImport(named name: String) -> ImportViewModel {
        let importer = ImportViewModel(scanner: TestPaths.scanner, skillStore: store,
            lockPath: lockPath, manifestService: manifest, manifestRoot: root)
        let source = root + "/source"
        importer.discoveredSkills = [DiscoveredSkill(name: name, body: "Imported body", sourcePlatform: "folder",
            sourcePath: source)]
        importer.selectedSkills = [source]
        return importer
    }

    func refreshWaitingWriteWindow() throws {
        try moveHead()
        _ = try StoreIngestState.rebuild(using: StoreRebuildService(fileService: files, manifestService: manifest),
            root: root, context: context, files: files)
        let requests = try manifest.snapshot(from: context).deployIntents.filter { $0.skillSlug == "zulu" }
        XCTAssertTrue(requests.contains { $0.machineID == peer && $0.projectKey == projects[1].identityKey })
        XCTAssertEqual(skill.directoryName, "zulu")
        XCTAssertEqual(saves.pendingCount, 1)
    }

    func waitingWriteArtifacts() throws -> [String: String] {
        var artifacts: [String: String] = [:]
        let parent = (root as NSString).deletingLastPathComponent
        let targets = [parent + "/agent", parent + "/rules"]
            + projects.flatMap { [$0.path + "/.claude/skills", $0.path + "/.cursor/rules"] }
        for target in targets {
            for slug in ["alpha", "zulu", "other"] {
                let path = target + "/" + slug + (target.hasSuffix("rules") ? ".mdc" : "")
                guard try files.entryExistsWithoutFollowingLinks(at: path) else { continue }
                artifacts[path] = files.isSymlink(at: path)
                    ? try files.symlinkTarget(at: path) : try files.readFile(at: path)
            }
        }
        return artifacts
    }
}
