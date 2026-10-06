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
        XCTAssertEqual(try manifest(h).read(fromRoot: h.root + "/sync").deployIntents.count, 2,
                       "The previous atomic manifest remains intact")
        XCTAssertEqual(category.projectKeys, keys, "Failed withdrawal publication must restore the saved prune")
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 2)
        XCTAssertEqual(try manifest(h).read(fromRoot: h.root + "/sync").categories.first?.projectKeys, keys)
        h.mapped.beforeFileWrite = nil
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
        XCTAssertTrue(try manifest(h).read(fromRoot: h.root + "/sync").deployIntents.isEmpty)
        for platform in [PlatformTarget.codex, .cursor] {
            XCTAssertFalse(try h.files.entryExistsWithoutFollowingLinks(at: h.platformVM.artifactPath(
                skill: h.skill, platform: platform, target: .project(project))))
        }
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
        removeRegisteredProject(project, categoryStore: CategoryStore(),
            reconciler: CategoryReconciler(platformVM: h.platformVM),
            manifestService: manifest(h), manifestRoot: h.root + "/sync",
            platformVM: h.platformVM, localMachineID: ProjectIntentHarness.localID,
            context: context)
    }

}
