import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ProjectRemovalFreshnessTests: XCTestCase {
    func testDeployWhileConfirmationIsOpenStopsWithoutOrphaningArtifacts() throws {
        for initiallyOwned in [false, true] {
            let h = try ProjectFolderCallerHarness(installed: [.claudeCode, .codex])
            defer { h.cleanup() }
            try h.files.createDirectory(at: h.project.path)
            if initiallyOwned {
                try h.addIntent(platform: .claudeCode)
                XCTAssertFalse(h.intent.reconcile(context: h.context).hasFailures)
            } else {
                let path = h.artifact(.codex)
                try h.files.createDirectory(at: (path as NSString).deletingLastPathComponent)
                try h.files.writeFile(at: path, content: "User file")
                try h.deployState.upsert(DeployStateRecord(slug: h.skill.directoryName, platform: "codex",
                    scope: "project", projectIdentityKey: h.project.identityKey, artifactPath: path, recordedAt: "old"))
            }
            let model = ProjectRemovalModel()
            model.request(h.project, platformVM: h.platformVM, context: h.context)
            XCTAssertEqual(model.preview?.artifactCount, initiallyOwned ? 1 : 0)
            if !initiallyOwned { try h.files.deleteFile(at: h.artifact(.codex)) }
            try h.addIntent(platform: .codex)
            XCTAssertFalse(h.intent.reconcile(context: h.context).hasFailures)
            let state = try h.deployState.read()
            let intentKeys = Set(try h.context.fetch(FetchDescriptor<MachineDeployIntent>()).map(\.key))
            let ledgerKeys = Set(try h.context.fetch(FetchDescriptor<IntentAssignment>()).map(\.key))
            let result = confirm(model, h)
            XCTAssertTrue(result.hasFailures, "Changed confirmation must stop before withdrawing or unlinking")
            XCTAssertTrue(model.error?.contains("The project changed while confirmation was open.") == true)
            XCTAssertFalse(model.error?.contains("project folder changed") == true)
            XCTAssertTrue(model.error?.contains("changed") == true)
            XCTAssertTrue(model.error?.contains("review") == true)
            XCTAssertTrue(h.files.isSymlink(at: h.artifact(.codex)))
            XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Project>()), 2)
            XCTAssertEqual(try h.deployState.read(), state)
            XCTAssertEqual(Set(try h.context.fetch(FetchDescriptor<MachineDeployIntent>()).map(\.key)), intentKeys)
            XCTAssertEqual(Set(try h.context.fetch(FetchDescriptor<IntentAssignment>()).map(\.key)), ledgerKeys)
        }
    }

    func testMissingFolderReturningAfterConfirmationRequiresReview() throws {
        let h = try ProjectFolderCallerHarness(installed: [.codex])
        defer { h.cleanup() }
        let model = ProjectRemovalModel()
        model.request(h.project, platformVM: h.platformVM, context: h.context)
        XCTAssertTrue(model.preview?.folderIsMissing == true)
        try h.files.createDirectory(at: h.project.path)
        try h.addIntent()
        XCTAssertFalse(h.intent.reconcile(context: h.context).hasFailures)
        let state = try h.deployState.read()
        XCTAssertTrue(confirm(model, h).hasFailures)
        XCTAssertTrue(model.error?.contains("changed") == true)
        XCTAssertTrue(h.files.isSymlink(at: h.artifact(.codex)))
        XCTAssertEqual(try h.deployState.read(), state)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Project>()), 2)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 1)
    }

    func testSameFolderSiblingWithoutRequestsKeepsAllArtifactsAndRecords() throws {
        for alias in [false, true] {
            for evidence in ["state", "history", "ledger"] {
                let h = try ProjectFolderCallerHarness(installed: [.claudeCode])
                defer { h.cleanup() }
                try h.files.createDirectory(at: h.project.path)
                h.otherProject.path = h.project.path
                if alias {
                    let link = h.root + "/alias"
                    try h.files.createSymlink(at: link, pointingTo: h.project.path)
                    h.otherProject.path = link
                }
                try LinkService(fileService: h.mapped).link(skill: h.skill, platform: .claudeCode, projectPath: h.project.path)
                let path = h.artifact(.claudeCode)
                h.context.insert(DeployRecord(skillID: h.skill.id, platform: .claudeCode,
                    targetPath: path, contentHash: "local", projectID: h.project.id))
                if evidence == "history" {
                    h.context.insert(DeployRecord(skillID: h.skill.id, platform: .claudeCode,
                        targetPath: h.artifact(.claudeCode, project: h.otherProject), contentHash: "sibling",
                        projectID: h.otherProject.id))
                } else {
                    try h.deployState.upsert(DeployStateRecord(slug: h.skill.directoryName, platform: "claudeCode",
                        scope: "project", projectIdentityKey: h.otherProject.identityKey,
                        artifactPath: h.artifact(.claudeCode, project: h.otherProject), recordedAt: "old"))
                }
                if evidence == "ledger" {
                    h.context.insert(SkillProjectAssignment(skillID: h.skill.id,
                        projectID: h.otherProject.id, platform: .claudeCode))
                }
                try h.context.save()
                let state = try h.deployState.read()
                let historyIDs = Set(try h.context.fetch(FetchDescriptor<DeployRecord>()).map(\.id))
                let ledgerIDs = Set(try h.context.fetch(FetchDescriptor<SkillProjectAssignment>()).map(\.id))
                let model = ProjectRemovalModel()
                model.request(h.project, platformVM: h.platformVM, context: h.context)
                XCTAssertEqual(model.preview?.artifactCount, 0)
                XCTAssertTrue(model.preview?.message.contains("other registration") == true)
                let reconciler = RemovalCheckpointReconciler(reconciler: h.category) {
                    h.mapped.beforeProjectProbe = { _ in throw NSError(domain: NSPOSIXErrorDomain, code: 13) }
                    return BatchResult()
                }
                XCTAssertFalse(confirm(model, h, reconciler: reconciler).hasFailures)
                XCTAssertTrue(h.files.isSymlink(at: path))
                XCTAssertEqual(try h.deployState.read(), state)
                XCTAssertEqual(Set(try h.context.fetch(FetchDescriptor<DeployRecord>()).map(\.id)), historyIDs)
                XCTAssertEqual(Set(try h.context.fetch(FetchDescriptor<SkillProjectAssignment>()).map(\.id)), ledgerIDs)
                XCTAssertEqual(try h.context.fetch(FetchDescriptor<Project>()).map(\.id), [h.otherProject.id])
            }
        }
    }

    func testFailureCopyDistinguishesNoRemovalFromRemovalBeforeStateSaveFailure() throws {
        for failure in ["preparation", "unlink", "state write"] {
            let h = try ProjectFolderCallerHarness(installed: [.codex])
            defer { h.cleanup() }
            try h.files.createDirectory(at: h.project.path)
            try h.addIntent()
            XCTAssertFalse(h.intent.reconcile(context: h.context).hasFailures)
            let category = try h.addCategory()
            let manifest = ManifestService(fileService: h.mapped)
            let root = h.root + "/sync"
            try manifest.write(try manifest.snapshot(from: h.context), toRoot: root)
            let model = ProjectRemovalModel()
            model.request(h.project, platformVM: h.platformVM, context: h.context)
            if failure == "state write" {
                h.mapped.beforeDeployStateWrite = { _ in throw NSError(domain: NSPOSIXErrorDomain, code: 5) }
            } else if failure == "unlink" {
                h.mapped.beforeArtifactDeletion = { _ in throw NSError(domain: NSPOSIXErrorDomain, code: 13) }
            } else {
                h.mapped.beforeProjectProbe = { _ in throw NSError(domain: NSPOSIXErrorDomain, code: 13) }
            }
            XCTAssertTrue(model.confirm { project, preview in
                removeRegisteredProject(project, reconciler: h.category, manifestService: manifest,
                    manifestRoot: root, platformVM: h.platformVM, localMachineID: ProjectIntentHarness.localID,
                    confirmedPreview: preview, context: h.context)
            }.hasFailures)
            let unchanged = failure == "preparation"
            XCTAssertEqual(h.files.isSymlink(at: h.artifact(.codex)), failure != "state write")
            XCTAssertEqual(model.error?.contains("stopped partway"), failure == "state write")
            XCTAssertEqual(model.error?.contains("Nothing was changed."), unchanged)
            XCTAssertEqual(model.error?.contains("Pensieve withdrew this Mac's direct deploy requests for this project."),
                           failure == "unlink")
            XCTAssertTrue(model.error?.contains(". It stays registered;") == true)
            XCTAssertTrue(model.error?.contains("retry to complete it.") == true)
            XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Project>()), 2)
            XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), unchanged ? 1 : 0)
            XCTAssertEqual(category.projectKeys, [h.project.identityKey!])
            XCTAssertEqual(try manifest.read(fromRoot: root).deployIntents.count, unchanged ? 1 : 0)
            XCTAssertEqual(try manifest.read(fromRoot: root).categories.first?.projectKeys,
                           [h.project.identityKey!])
        }
    }

    private func confirm(_ model: ProjectRemovalModel, _ h: ProjectFolderCallerHarness,
                         reconciler: CategoryReconcilerProtocol? = nil) -> BatchResult {
        model.confirm { project, plan in
            removeRegisteredProject(project, reconciler: reconciler ?? h.category,
                platformVM: h.platformVM, localMachineID: ProjectIntentHarness.localID, confirmedPreview: plan,
                context: h.context)
        }
    }
}
