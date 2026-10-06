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
                XCTAssertFalse(confirm(model, h).hasFailures)
                XCTAssertTrue(h.files.isSymlink(at: path))
                XCTAssertEqual(try h.deployState.read(), state)
                XCTAssertEqual(Set(try h.context.fetch(FetchDescriptor<DeployRecord>()).map(\.id)), historyIDs)
                XCTAssertEqual(Set(try h.context.fetch(FetchDescriptor<SkillProjectAssignment>()).map(\.id)), ledgerIDs)
                XCTAssertEqual(try h.context.fetch(FetchDescriptor<Project>()).map(\.id), [h.otherProject.id])
            }
        }
    }

    func testFailureCopyDistinguishesNoRemovalFromRemovalBeforeStateSaveFailure() throws {
        for stateFailure in [false, true] {
            let h = try ProjectFolderCallerHarness(installed: [.codex])
            defer { h.cleanup() }
            try h.files.createDirectory(at: h.project.path)
            try h.addIntent()
            XCTAssertFalse(h.intent.reconcile(context: h.context).hasFailures)
            if stateFailure {
                h.mapped.beforeDeployStateWrite = { _ in throw NSError(domain: NSPOSIXErrorDomain, code: 5) }
            } else {
                h.mapped.beforeArtifactDeletion = { _ in throw NSError(domain: NSPOSIXErrorDomain, code: 13) }
            }
            let model = ProjectRemovalModel()
            model.request(h.project, platformVM: h.platformVM, context: h.context)
            XCTAssertTrue(confirm(model, h).hasFailures)
            XCTAssertEqual(h.files.isSymlink(at: h.artifact(.codex)), !stateFailure)
            XCTAssertEqual(model.error?.contains("stopped partway"), stateFailure)
            XCTAssertEqual(model.error?.contains("Nothing was changed."), !stateFailure)
            XCTAssertTrue(model.error?.contains(". It stays registered;") == true)
            XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Project>()), 2)
        }
    }

    private func confirm(_ model: ProjectRemovalModel, _ h: ProjectFolderCallerHarness) -> BatchResult {
        model.confirm { project, plan in
            removeRegisteredProject(project, reconciler: h.category,
                platformVM: h.platformVM, localMachineID: ProjectIntentHarness.localID, confirmedPreview: plan,
                context: h.context)
        }
    }
}
