import CoreData
import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class WaitingRemovalRoundTwoTests: XCTestCase {
    func testLateProjectSaveFailureKeepsStateOnlyWaitingEvidenceForOfflineRetry() throws {
        let h = try WaitingRemovalHarness(persistent: true)
        defer { h.base.cleanup() }
        try h.base.files.createDirectory(at: h.base.project.path)
        try LinkService(fileService: h.mapped).link(skill: h.base.skill, platform: .codex, projectPath: h.base.project.path)
        try h.base.deployState.upsert(DeployStateRecord(slug: h.base.skill.directoryName, platform: "codex",
            scope: "project", projectIdentityKey: h.base.project.identityKey,
            artifactPath: h.base.artifact(.codex), recordedAt: "original"))
        try h.hideFolder()
        let fault = ProjectRemovalSaveFault(root: h.base.root)
        defer { fault.stop() }
        var savedWaiting: [WaitingRemoval] = []
        h.base.mapped.beforeDeployStateWrite = { _ in
            savedWaiting = try h.vm.waitingRemovalStore.read()
            fault.enabled = true
        }
        let result = h.removeProject()
        h.base.mapped.beforeDeployStateWrite = nil
        XCTAssertEqual(fault.refusedSaves, 1)
        XCTAssertTrue(result.operationFailures.contains { $0.contains("Couldn't save project removal") })
        XCTAssertEqual(try h.base.context.fetchCount(FetchDescriptor<Project>()), 2)
        XCTAssertTrue(try h.base.deployState.read().records.isEmpty, "State-only evidence was retired")
        XCTAssertEqual(savedWaiting.count, 1)
        XCTAssertEqual(try h.vm.waitingRemovalStore.read(), savedWaiting,
            "A late save failure must preserve the only remaining cleanup evidence")
        XCTAssertFalse(h.removeProject().hasFailures)
        XCTAssertEqual(try h.base.context.fetchCount(FetchDescriptor<Project>()), 1)
        XCTAssertEqual(try h.vm.waitingRemovalStore.read(), savedWaiting, "An offline retry must not duplicate waiting work")
        try h.restoreFolder()
        XCTAssertFalse(h.vm.reconcileWaitingRemovals(context: h.base.context).hasFailures)
        XCTAssertFalse(h.base.files.isSymlink(at: h.base.artifact(.codex)))
        XCTAssertTrue(try h.vm.waitingRemovalStore.read().isEmpty)
    }

    func testWaitingPromiseDriftRefusesConfirmedProjectRemoval() throws {
        for addingEvidence in [false, true] {
            let h = try WaitingRemovalHarness()
            defer { h.base.cleanup() }
            let row = DeployStateRecord(slug: h.base.skill.directoryName, platform: "codex", scope: "project",
                projectIdentityKey: h.base.project.identityKey, artifactPath: h.base.artifact(.codex), recordedAt: "original")
            if !addingEvidence { try h.base.deployState.upsert(row) }
            let preview = try ProjectRemovalPlan.prepare(project: h.base.project, platformVM: h.vm,
                context: h.base.context).preview
            if addingEvidence { try h.base.deployState.upsert(row) } else {
                _ = try h.base.deployState.remove(artifactPaths: [row.artifactPath])
            }
            let records = try h.base.deployState.read().records
            let result = removeRegisteredProject(h.base.project, reconciler: h.base.category, platformVM: h.vm,
                localMachineID: ProjectIntentHarness.localID, confirmedPreview: preview, context: h.base.context)
            XCTAssertEqual(result.operationFailures,
                ["The project changed while confirmation was open. Please review removal again."],
                "A changed waiting-cleanup promise must require a fresh confirmation")
            XCTAssertEqual(try h.base.context.fetchCount(FetchDescriptor<Project>()), 2)
            XCTAssertEqual(try h.base.deployState.read().records, records)
            XCTAssertTrue(try h.vm.waitingRemovalStore.read().isEmpty)
        }
    }
}

/// Injects one validation failure at the final real SwiftData project-delete save, scoped to this
/// persistent fixture. The deploy-state write enables it; rollback discards the invalid insertion.
private final class ProjectRemovalSaveFault {
    var enabled = false
    private(set) var refusedSaves = 0
    private var observer: NSObjectProtocol?

    init(root: String) {
        observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextWillSave,
            object: nil, queue: nil) { [weak self] notification in
                guard let self, self.enabled, self.refusedSaves == 0,
                      let context = notification.object as? NSManagedObjectContext,
                      let project = context.deletedObjects.first(where: { $0.entity.name?.hasSuffix("Project") == true })
                else { return }
                var owner = context
                while let parent = owner.parent { owner = parent }
                guard owner.persistentStoreCoordinator?.persistentStores.contains(where: {
                    $0.url?.path == root + "/removal.sqlite"
                }) == true else { return }
                self.refusedSaves += 1
                _ = ProjectRemovalValidationFailure(entity: project.entity, insertInto: context)
            }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

private final class ProjectRemovalValidationFailure: NSManagedObject {
    override func validateForInsert() throws {
        throw NSError(domain: NSCocoaErrorDomain, code: NSValidationMissingMandatoryPropertyError,
            userInfo: [NSLocalizedDescriptionKey: "Final project save refused"])
    }
}
