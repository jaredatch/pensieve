import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ProjectRemovalDurabilityTests: XCTestCase {
    func testFailedProjectSaveKeepsRegistrationAndRelaunchRetryWithdrawsManifestIntent() throws {
        try assertLocalOnlyRemovalRecovers()
        try assertPendingWithdrawalRefuses()
        let h = try fixture()
        defer { h.cleanup() }
        let readOnly = try AppRuntime.makeContainer(configuration: ModelConfiguration(
            url: URL(fileURLWithPath: h.root + "/removal.sqlite"), allowsSave: false))
        let context = ModelContext(readOnly)
        let projectID = h.project.id
        let project = try XCTUnwrap(try context.fetch(FetchDescriptor<Project>()).first { $0.id == projectID })
        let name = project.name
        let result = remove(h, project: project, context: context)
        XCTAssertTrue(result.hasFailures, "A read-only persistent store must report the refused save")
        guard result.hasFailures else { return }
        XCTAssertTrue(ProjectRemovalModel.removalFailureMessage(projectName: name, result: result)
            .contains("stays registered"))
        XCTAssertEqual(try manifest(h).read(fromRoot: h.root + "/sync").deployIntents.count, 2,
                       "A refused save must leave the manifest agreeing with the registered project's intents")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 2)
        try relaunchAndRetry(h, projectID: projectID)
    }

    private func assertPendingWithdrawalRefuses() throws {
        let h = try fixture()
        defer { h.cleanup() }
        var pulled = try manifest(h).read(fromRoot: h.root + "/sync")
        pulled.deployIntents.append(DeployIntentRecord(machineID: ProjectIntentHarness.localID,
            skillSlug: "peer-added", platformRaw: "codex", projectKey: h.project.identityKey))
        try manifest(h).write(pulled, toRoot: h.root + "/sync")
        let readOnly = try AppRuntime.makeContainer(configuration: ModelConfiguration(
            url: URL(fileURLWithPath: h.root + "/removal.sqlite"), allowsSave: false))
        let context = ModelContext(readOnly)
        let project = try XCTUnwrap(context.fetch(FetchDescriptor<Project>()).first { $0.id == h.project.id })
        XCTAssertThrowsError(try StoreIngestState.rebuild(
            using: StoreRebuildService(manifestService: manifest(h)), root: h.root + "/sync", context: ModelContext(readOnly)))
        XCTAssertTrue(StoreIngestState.shared(for: readOnly).needsRebuild)
        var writes = 0
        h.mapped.beforeFileWrite = { path in
            if path.contains(".manifest-build-") { writes += 1 }
        }
        let result = remove(h, project: project, context: context)
        XCTAssertTrue(result.hasFailures)
        XCTAssertEqual(result.operationFailures,
            ["Project removal couldn't update this Mac's library. Try removing the project again."])
        XCTAssertEqual(writes, 0, "pending ingestion must not repair from the stale window")
        XCTAssertEqual(try manifest(h).read(fromRoot: h.root + "/sync"), pulled)
        XCTAssertTrue(StoreIngestState.shared(for: readOnly).needsRebuild)
    }

    func testBusySyncRefusesBeforeWithdrawalOrArtifactCleanup() throws {
        let h = try fixture()
        defer { h.cleanup() }
        let saved = try manifest(h).read(fromRoot: h.root + "/sync")
        let state = try h.deployState.read()
        let requests = try h.context.fetch(FetchDescriptor<MachineDeployIntent>()).map(\.key)
        var artifactEffects: [String] = []
        h.mapped.beforeArtifactDeletion = { artifactEffects.append($0) }
        h.mapped.beforeArtifactCreation = { artifactEffects.append($0) }
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.root + "/support.sync.lock"))
        defer { lock.release() }
        let result = remove(h, project: h.project, context: h.context)
        XCTAssertEqual(result.operationFailures, ["Sync is running. Try again when it finishes."])
        XCTAssertTrue(artifactEffects.isEmpty)
        XCTAssertEqual(try manifest(h).read(fromRoot: h.root + "/sync"), saved)
        XCTAssertEqual(try h.context.fetch(FetchDescriptor<MachineDeployIntent>()).map(\.key), requests)
        XCTAssertEqual(try h.deployState.read(), state)
        XCTAssertTrue(try h.context.fetch(FetchDescriptor<Project>()).contains { $0.id == h.project.id })
        for platform in [PlatformTarget.codex, .cursor] {
            XCTAssertTrue(try h.platformVM.removalOperation(skill: h.skill, platform: platform,
                target: .project(h.project)).classify().isOwned)
        }
        lock.release()
        try h.files.deleteFile(at: h.root + "/support.sync.lock")
        try h.files.createDirectory(at: h.root + "/support.sync.lock")
        let inaccessible = remove(h, project: h.project, context: h.context)
        XCTAssertTrue(inaccessible.hasFailures)
        XCTAssertTrue(inaccessible.operationFailures.contains { $0.contains("lock") && !$0.contains("Sync is running") },
            "A broken lock needs its own actionable error")
        XCTAssertTrue(artifactEffects.isEmpty)
        XCTAssertEqual(try manifest(h).read(fromRoot: h.root + "/sync"), saved)
        XCTAssertEqual(try h.context.fetch(FetchDescriptor<MachineDeployIntent>()).map(\.key), requests)
    }

    func testFailedManifestWriteKeepsRegistrationAndRelaunchRetryWithdrawsIntent() throws {
        let h = try fixture()
        defer { h.cleanup() }
        let category = try h.addCategory()
        try manifest(h).write(try manifest(h).snapshot(from: h.context), toRoot: h.root + "/sync")
        let keys = category.projectKeys
        var faulted = false
        var artifactEffects: [String] = []
        h.mapped.beforeArtifactDeletion = { artifactEffects.append($0) }
        h.mapped.beforeArtifactCreation = { artifactEffects.append($0) }
        h.mapped.beforeFileWrite = { path in
            if path.contains(".manifest-build-") && path.hasSuffix("/manifest.yaml") {
                faulted = true
                throw NSError(domain: NSPOSIXErrorDomain, code: 5)
            }
        }
        let projectID = h.project.id
        let result = remove(h, project: h.project, context: h.context)
        XCTAssertTrue(faulted, "The real manifest writer must reach the fault")
        XCTAssertTrue(artifactEffects.isEmpty, "A refused publication must attempt no artifact write or deletion")
        XCTAssertTrue(result.hasFailures)
        XCTAssertTrue(ProjectRemovalModel.removalFailureMessage(projectName: h.project.name, result: result)
            .contains("stays registered"))
        let message = ProjectRemovalModel.removalFailureMessage(projectName: h.project.name, result: result)
        XCTAssertFalse(message.contains(".:"))
        XCTAssertFalse(message.contains("stopped partway"))
        XCTAssertTrue(message.contains("Nothing was changed."))
        XCTAssertEqual(try manifest(h).read(fromRoot: h.root + "/sync").deployIntents.count, 2,
                       "The previous atomic manifest remains intact")
        XCTAssertEqual(category.projectKeys, keys, "Withdrawal leaves shared category membership unchanged")
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 2)
        XCTAssertEqual(try manifest(h).read(fromRoot: h.root + "/sync").categories.first?.projectKeys, keys)
        for platform in [PlatformTarget.codex, .cursor] {
            XCTAssertTrue(try h.platformVM.removalOperation(skill: h.skill, platform: platform,
                target: .project(h.project)).classify().isOwned, "Publish refusal must preserve the deployed artifact")
        }
        h.mapped.beforeFileWrite = nil
        try relaunchAndRetry(h, projectID: projectID)
        XCTAssertEqual(try manifest(h).read(fromRoot: h.root + "/sync").categories.first?.projectKeys, keys)
        XCTAssertEqual(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).first?.projectKeys, keys)
    }

    func testFailedPublishAndRestoreSaveRetryRepublishesSavedWithdrawal() throws {
        let h = try fixture()
        defer { h.cleanup() }
        let fault = RestorationSaveFault(root: h.root)
        defer { fault.stop() }
        let context = h.context
        let projectID = h.project.id
        let project = try XCTUnwrap(try context.fetch(FetchDescriptor<Project>()).first { $0.id == projectID })
        var faulted = false
        var logs: [String] = []
        h.mapped.beforeFileWrite = { path in
            guard path.contains(".manifest-build-"), path.hasSuffix("/manifest.yaml") else { return }
            guard !faulted else { return }
            faulted = true
            fault.refusesRestore = true
            throw NSError(domain: NSPOSIXErrorDomain, code: 5)
        }
        let result = removeRegisteredProject(project, reconciler: h.category,
            manifestService: manifest(h), manifestRoot: h.root + "/sync", platformVM: h.platformVM,
            localMachineID: ProjectIntentHarness.localID, context: context, logFailure: { logs.append($0) },
            lockPath: h.root + "/support" + ".sync.lock")
        XCTAssertTrue(faulted)
        XCTAssertTrue(result.hasFailures)
        XCTAssertTrue(logs.contains { $0.contains("restore project withdrawal") }, "The restoring save must actually fail")
        XCTAssertEqual(fault.refusedSaves, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
        XCTAssertEqual(try manifest(h).read(fromRoot: h.root + "/sync").deployIntents.count, 0,
            "Repair must republish the withdrawal that remains saved")
        let message = ProjectRemovalModel.removalFailureMessage(projectName: project.name, result: result)
        XCTAssertFalse(message.contains("Nothing was changed."), "The withdrawal remains saved after restoration fails")
        XCTAssertTrue(message.contains("Pensieve withdrew this Mac's direct deploy requests for this project."))
        h.mapped.beforeFileWrite = nil
        fault.refusesRestore = false
        try relaunchAndRetry(h, projectID: projectID)
    }

    private func relaunchAndRetry(_ h: ProjectFolderCallerHarness, projectID: UUID) throws {
        let container = try AppRuntime.makeContainer(
            configuration: ModelConfiguration(url: URL(fileURLWithPath: h.root + "/removal.sqlite")))
        let context = ModelContext(container)
        let project = try XCTUnwrap(try context.fetch(FetchDescriptor<Project>()).first { $0.id == projectID },
                                   "The saved registration must survive a fresh container")
        XCTAssertFalse(remove(h, project: project, context: context).hasFailures)
        XCTAssertFalse(try context.fetch(FetchDescriptor<Project>()).contains { $0.id == projectID })
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
        XCTAssertTrue(try manifest(h).read(fromRoot: h.root + "/sync").deployIntents.isEmpty,
                      "Retry must publish the saved withdrawal even when no request facts change")
        for platform in [PlatformTarget.codex, .cursor] {
            XCTAssertFalse(try h.files.entryExistsWithoutFollowingLinks(at: h.platformVM.artifactPath(
                skill: h.skill, platform: platform, target: .project(project))))
        }
    }

    func testFinalRegistrationSaveFailureDoesNotRepublishManifest() throws {
        let h = try ProjectFolderCallerHarness(persistent: true)
        defer { h.cleanup() }
        try h.files.createDirectory(at: h.project.path)
        let readOnly = try AppRuntime.makeContainer(configuration: ModelConfiguration(
            url: URL(fileURLWithPath: h.root + "/removal.sqlite"), allowsSave: false))
        let context = ModelContext(readOnly)
        let projectID = h.project.id
        let project = try XCTUnwrap(try context.fetch(FetchDescriptor<Project>()).first { $0.id == projectID })
        var reconciled = false, lateWrites = 0
        h.mapped.beforeFileWrite = { path in
            if reconciled && path.contains(".manifest-build-") && path.hasSuffix("/manifest.yaml") { lateWrites += 1 }
        }
        let result = removeRegisteredProject(project,
            reconciler: RemovalCheckpointReconciler { reconciled = true; return BatchResult() },
            manifestService: manifest(h), manifestRoot: h.root + "/sync", platformVM: h.platformVM,
            localMachineID: ProjectIntentHarness.localID, context: context,
            lockPath: h.root + "/support" + ".sync.lock")
        XCTAssertTrue(result.hasFailures)
        XCTAssertTrue(reconciled, "The refused save follows the withdrawal and reconcile")
        XCTAssertEqual(lateWrites, 0, "Registration and ledger rollback cannot change the manifest snapshot")
        let saved = try AppRuntime.makeContainer(configuration: ModelConfiguration(
            url: URL(fileURLWithPath: h.root + "/removal.sqlite")))
        XCTAssertEqual(try ModelContext(saved).fetchCount(FetchDescriptor<Project>()), 2)
    }

    func testRemovalUsesOnlyCallersManifestService() throws {
        let h = try fixture()
        defer { h.cleanup() }
        var writes = 0
        h.mapped.beforeFileWrite = { path in
            if path.contains(".manifest-build-") && path.hasSuffix("/manifest.yaml") {
                writes += 1
                throw NSError(domain: NSPOSIXErrorDomain, code: 5)
            }
        }
        let result = removeRegisteredProject(
            h.project,
            reconciler: h.category, manifestRoot: TestPaths.storeRoot,
            platformVM: h.platformVM,
            localMachineID: ProjectIntentHarness.localID,
            context: h.context,
            lockPath: h.root + "/support" + ".sync.lock")
        XCTAssertFalse(result.hasFailures, "A category CRUD publication dependency must not control project removal")
        XCTAssertEqual(writes, 0, "The caller provided no manifest service")
        XCTAssertEqual(try h.context.fetch(FetchDescriptor<Project>()).map(\.id), [h.otherProject.id])
    }

    private func fixture() throws -> ProjectFolderCallerHarness {
        let h = try ProjectFolderCallerHarness(installed: [.codex, .cursor], persistent: true)
        try h.files.createDirectory(at: h.project.path)
        for platform in [PlatformTarget.codex, .cursor] { try h.addIntent(platform: platform) }
        XCTAssertFalse(h.intent.reconcile(context: h.context).hasFailures)
        try manifest(h).write(try manifest(h).snapshot(from: h.context), toRoot: h.root + "/sync")
        return h
    }

    private func manifest(_ h: ProjectFolderCallerHarness) -> ManifestService { ManifestService(fileService: h.mapped) }

    private func remove(_ h: ProjectFolderCallerHarness, project: Project, context: ModelContext,
                        manifestRoot: String? = nil) -> BatchResult {
        removeRegisteredProject(project,
            reconciler: CategoryReconciler(platformVM: h.platformVM),
            manifestService: manifest(h), manifestRoot: manifestRoot ?? h.root + "/sync",
            platformVM: h.platformVM, localMachineID: ProjectIntentHarness.localID,
            context: context,
            lockPath: h.root + "/support" + ".sync.lock")
    }

}

private extension ProjectRemovalDurabilityTests {
    func assertLocalOnlyRemovalRecovers() throws {
        let h = try fixture()
        defer { h.cleanup() }
        let root = h.root + "/store", lockPath = h.root + "/support.sync.lock"
        let service = manifest(h), git = GitService(fileService: h.files, askpassHelperPath: h.root + "/unused-askpass")
        var disk = try service.snapshot(from: h.context)
        disk.categories = [CategoryRecord(name: "Added", projectKeys: [], skillSlugs: [])]
        disk.deployIntents.append(DeployIntentRecord(machineID: ProjectIntentHarness.localID,
            skillSlug: h.skill.directoryName, platformRaw: "claudeCode", projectKey: h.project.identityKey))
        let kept = DeployIntentRecord(machineID: ProjectIntentHarness.localID,
            skillSlug: h.skill.directoryName, platformRaw: "codex", projectKey: h.otherProject.identityKey)
        disk.deployIntents.append(kept)
        try service.write(disk, toRoot: root)
        let container = h.context.container
        let launch = try NativeTestWork.run(container: container) { context in
            try git.initRepository(at: root)
            return LaunchReconciler(
                rebuildService: StoreRebuildService(manifestService: service, save: { _ in
                    throw CocoaError(.fileWriteUnknown)
                }),
                migrationService: StoreMigrationService(manifestService: service, skillStore: SkillStore(
                    fileService: h.files, baseDir: root + "/skills", storeRoot: root)),
                fileService: h.files, manifestService: service, root: root, lockPath: lockPath, git: git)
                .reconcileOnLaunch(context: context, alreadyMigrated: true)
        }
        XCTAssertTrue(launch.rebuild.saveFailed)
        XCTAssertNil(launch.ingestedHeadStamp)
        XCTAssertTrue(launch.ingestionNeedsRetry, "An incomplete local launch keeps its retry scheduled")
        let sync = try NativeTestWork.run(container: container) { context in
            try SyncEngine(gitService: git, manifestService: service,
                storeRebuildService: StoreRebuildService(manifestService: service, save: { _ in
                    throw CocoaError(.fileWriteUnknown)
                }), lockPath: lockPath)
                .sync(root: root, message: "Local-only retry", credential: nil, context: context)
        }
        XCTAssertEqual(sync, .noRemote)
        XCTAssertTrue(StoreIngestState.shared(for: container).needsRebuild)
        let projectID = h.project.id
        let artifacts = [PlatformTarget.codex, .cursor].map { h.artifact($0) }
        let result = remove(h, project: h.project, context: h.context, manifestRoot: root)
        XCTAssertFalse(result.hasFailures, "removal must recover locally without a remote or relaunch")
        XCTAssertFalse(StoreIngestState.shared(for: container).needsRebuild)
        let saved = ModelContext(container)
        XCTAssertFalse(try saved.fetch(FetchDescriptor<Project>()).contains { $0.id == projectID })
        XCTAssertEqual(try saved.fetch(FetchDescriptor<MachineDeployIntent>()).map(\.projectKey), [kept.projectKey])
        let published = try service.read(fromRoot: root)
        XCTAssertEqual(published.deployIntents, [kept], "withdrawal must include intents ingested by this attempt")
        XCTAssertEqual(published.categories.map(\.name), ["Added"])
        for path in artifacts { XCTAssertFalse(try h.files.entryExistsWithoutFollowingLinks(at: path)) }
    }

}
