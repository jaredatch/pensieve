import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ProjectRemovalDurabilityTests: XCTestCase {
    func testFailedProjectSaveKeepsRegistrationAndRelaunchRetryWithdrawsManifestIntent() throws {
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
        XCTAssertTrue(ProjectListView.removalFailureMessage(projectName: name, result: result)
            .contains("stays registered"))
        XCTAssertEqual(try manifest(h).read(fromRoot: h.root + "/sync").deployIntents.count, 2,
                       "A refused save must leave the manifest agreeing with the registered project's intents")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 2)
        try relaunchAndRetry(h, projectID: projectID)
    }

    func testFailedManifestWriteKeepsRegistrationAndRelaunchRetryWithdrawsIntent() throws {
        let h = try fixture()
        defer { h.cleanup() }
        let category = try h.addCategory()
        try manifest(h).write(try manifest(h).snapshot(from: h.context), toRoot: h.root + "/sync")
        let keys = category.projectKeys
        var faulted = false
        h.mapped.beforeFileWrite = { path in
            if path.contains(".manifest-build-") && path.hasSuffix("/manifest.yaml") {
                faulted = true
                throw NSError(domain: NSPOSIXErrorDomain, code: 5)
            }
        }
        let projectID = h.project.id
        let result = remove(h, project: h.project, context: h.context)
        XCTAssertTrue(faulted, "The real manifest writer must reach the fault")
        XCTAssertTrue(result.hasFailures)
        XCTAssertTrue(ProjectListView.removalFailureMessage(projectName: h.project.name, result: result)
            .contains("stays registered"))
        let message = ProjectListView.removalFailureMessage(projectName: h.project.name, result: result)
        XCTAssertFalse(message.contains(".:"))
        XCTAssertFalse(message.contains("stopped partway"))
        XCTAssertTrue(message.contains("Nothing was changed."))
        XCTAssertEqual(try manifest(h).read(fromRoot: h.root + "/sync").deployIntents.count, 2,
                       "The previous atomic manifest remains intact")
        XCTAssertEqual(category.projectKeys, keys, "Failed withdrawal publication must restore the saved prune")
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 2)
        XCTAssertEqual(try manifest(h).read(fromRoot: h.root + "/sync").categories.first?.projectKeys, keys)
        h.mapped.beforeFileWrite = nil
        try relaunchAndRetry(h, projectID: projectID)
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
            faulted = true
            fault.refusesRestore = true
            throw NSError(domain: NSPOSIXErrorDomain, code: 5)
        }
        let result = removeRegisteredProject(project, reconciler: h.category,
            manifestService: manifest(h), manifestRoot: h.root + "/sync", platformVM: h.platformVM,
            localMachineID: ProjectIntentHarness.localID, context: context, logFailure: { logs.append($0) })
        XCTAssertTrue(faulted)
        XCTAssertTrue(result.hasFailures)
        XCTAssertTrue(logs.contains { $0.contains("restore project withdrawal") }, "The restoring save must actually fail")
        XCTAssertEqual(fault.refusedSaves, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
        XCTAssertEqual(try manifest(h).read(fromRoot: h.root + "/sync").deployIntents.count, 2)
        let message = ProjectListView.removalFailureMessage(projectName: project.name, result: result)
        XCTAssertFalse(message.contains("Nothing was changed."), "The withdrawal remains saved after restoration fails")
        XCTAssertTrue(message.contains("Pensieve stopped requesting this project's deploys."))
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
            localMachineID: ProjectIntentHarness.localID, context: context)
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
        let result = removeRegisteredProject(h.project,
            reconciler: h.category, platformVM: h.platformVM,
            localMachineID: ProjectIntentHarness.localID, context: h.context)
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

    private func remove(_ h: ProjectFolderCallerHarness, project: Project, context: ModelContext) -> BatchResult {
        removeRegisteredProject(project,
            reconciler: CategoryReconciler(platformVM: h.platformVM),
            manifestService: manifest(h), manifestRoot: h.root + "/sync",
            platformVM: h.platformVM, localMachineID: ProjectIntentHarness.localID,
            context: context)
    }

}
