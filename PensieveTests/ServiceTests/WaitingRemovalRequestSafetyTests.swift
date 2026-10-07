import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class WaitingRemovalRequestSafetyTests: XCTestCase {
    func testKeylessDirectRedeployProtectsReinstalledSkillFromWaitingCleanup() throws {
        let h = try WaitingRemovalHarness()
        defer { h.base.cleanup() }
        h.base.project.identityKey = nil
        try h.base.files.createDirectory(at: h.base.project.path)
        XCTAssertFalse(try h.base.model().set(true, skill: h.base.skill, platform: .codex,
            target: .project(h.base.project), context: h.base.context).hasFailures)
        // Seed the original deployment's local evidence; this baseline also skipped keyless writes.
        try h.base.deployState.upsert(DeployStateRecord(slug: h.base.skill.directoryName, platform: "codex",
            scope: "project", projectIdentityKey: nil, artifactPath: h.base.artifact(.codex), recordedAt: "original"))
        try h.hideFolder()
        XCTAssertTrue(h.deleteSkill())
        XCTAssertEqual(try h.vm.waitingRemovalStore.read().count, 1)
        let slug = try SkillStore(fileService: h.mapped).createSkill(
            name: "Caller Skill", description: "Replacement", body: "# Replacement")
        let replacement = Skill(name: "Caller Skill", directoryName: slug)
        h.base.context.insert(replacement)
        try h.restoreFolder()
        XCTAssertFalse(try h.base.model().set(true, skill: replacement, platform: .codex,
            target: .project(h.base.project), context: h.base.context).hasFailures)
        XCTAssertFalse(h.vm.reconcileWaitingRemovals(context: h.base.context).hasFailures)
        XCTAssertTrue(h.base.files.isSymlink(at: h.base.artifact(.codex)), "A current direct deploy must survive")
        XCTAssertTrue(try h.vm.waitingRemovalStore.read().isEmpty)
        XCTAssertEqual(try h.base.deployState.read().records.map(\.artifactPath), [h.base.artifact(.codex)])
        XCTAssertEqual(try h.base.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
        XCTAssertEqual(try h.base.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
    }

    func testKeylessAliasDirectDeploySurvivesOtherOfflineRegistrationRemoval() throws {
        let h = try WaitingRemovalHarness()
        defer { h.base.cleanup() }
        h.base.project.identityKey = nil
        h.base.otherProject.identityKey = nil
        try h.base.files.createDirectory(at: h.base.project.path)
        let alias = h.base.root + "/alias"
        try h.base.files.createSymlink(at: alias, pointingTo: h.base.project.path)
        h.base.otherProject.path = alias
        for project in [h.base.project, h.base.otherProject] {
            XCTAssertFalse(try h.base.model().set(true, skill: h.base.skill, platform: .codex,
                target: .project(project), context: h.base.context).hasFailures)
        }
        try h.hideFolder()
        XCTAssertFalse(h.removeProject().hasFailures)
        try h.restoreFolder()
        XCTAssertFalse(h.vm.reconcileWaitingRemovals(context: h.base.context).hasFailures)
        XCTAssertTrue(h.base.files.isSymlink(at: h.base.artifact(.codex)), "The surviving registration still deployed it")
        XCTAssertTrue(try h.vm.waitingRemovalStore.read().isEmpty)
        XCTAssertEqual(try h.base.deployState.read().records.map(\.artifactPath),
                       [h.base.artifact(.codex, project: h.base.otherProject)])
    }

    func testUnassignedKeylessHistoryCannotProtectAnOlderWaitingArtifact() throws {
        let h = try WaitingRemovalHarness()
        defer { h.base.cleanup() }
        h.base.project.identityKey = nil
        try h.base.files.createDirectory(at: h.base.project.path)
        let model = h.base.model()
        XCTAssertFalse(try model.set(true, skill: h.base.skill, platform: .codex,
            target: .project(h.base.project), context: h.base.context).hasFailures)
        try h.vm.waitingRemovalStore.add([h.entry()])
        XCTAssertFalse(try model.set(false, skill: h.base.skill, platform: .codex,
            target: .project(h.base.project), context: h.base.context).hasFailures)
        XCTAssertTrue(try h.base.deployState.read().records.isEmpty)
        XCTAssertEqual(try h.base.context.fetchCount(FetchDescriptor<DeployRecord>()), 1)
        // An older artifact can return after un-assignment; history still exists but no request does.
        try LinkService(fileService: h.mapped).link(skill: h.base.skill, platform: .codex, projectPath: h.base.project.path)
        XCTAssertFalse(h.vm.reconcileWaitingRemovals(context: h.base.context).hasFailures)
        XCTAssertFalse(h.base.files.isSymlink(at: h.base.artifact(.codex)))
        XCTAssertTrue(try h.vm.waitingRemovalStore.read().isEmpty)
    }

    func testUnreadableDeployStatePausesEveryReadyWaitingRemoval() throws {
        let h = try WaitingRemovalHarness(platforms: [.claudeCode, .codex])
        defer { h.base.cleanup() }
        try h.deploy([.claudeCode, .codex])
        try h.hideFolder()
        XCTAssertFalse(h.removeProject().hasFailures)
        try h.restoreFolder()
        let waiting = try h.vm.waitingRemovalStore.read()
        let statePath = h.base.root + "/support/deploy-state.json"
        try h.base.files.writeFile(at: statePath, content: "unreadable")
        XCTAssertTrue(h.vm.reconcileWaitingRemovals(context: h.base.context).hasFailures)
        XCTAssertEqual(try h.vm.waitingRemovalStore.read(), waiting)
        for entry in waiting { XCTAssertTrue(try h.base.files.entryExistsWithoutFollowingLinks(at: entry.artifactPath)) }
        XCTAssertEqual(try h.base.files.readFile(at: statePath), "unreadable")
    }

    func testChangedIdentityStillCleansWaitingOwnedLinkAndMarkedRule() throws {
        for identity in ["renamed", "unparseable", "absent", "unreadable"] {
            let h = try WaitingRemovalHarness(platforms: [.codex, .cursor])
            defer { h.base.cleanup() }
            try h.deploy([.codex, .cursor])
            try h.hideFolder()
            XCTAssertFalse(h.removeProject().hasFailures)
            try h.restoreFolder()
            let config = h.base.project.path + "/.git/config"
            if identity == "renamed" {
                try h.base.files.writeFile(at: config,
                    content: "[remote \"origin\"]\nurl = https://github.com/team/different.git\n")
            } else if identity == "unparseable" {
                try h.base.files.writeFile(at: config, content: "[remote \"origin\"]\nurl = /local/repository\n")
            } else if identity == "absent" { try h.base.files.deleteFile(at: config) } else if identity == "unreadable" {
                try h.base.files.deleteFile(at: config)
                try h.base.files.createDirectory(at: config)
            }
            let waiting = try h.vm.waitingRemovalStore.read()
            let rule = h.vm.artifactPath(skill: h.base.skill, platform: .cursor, target: .project(h.base.project))
            XCTAssertEqual(waiting.count, 2)
            XCTAssertTrue(h.base.files.isSymlink(at: h.base.artifact(.codex)))
            XCTAssertFalse(h.base.files.isSymlink(at: rule), identity)
            let ruleLines = try h.mapped.readFile(at: rule).components(separatedBy: "\n")
            XCTAssertEqual(ruleLines.first, "---", identity)
            let closingLine = try XCTUnwrap(ruleLines.dropFirst().firstIndex(of: "---"), identity)
            XCTAssertTrue(ruleLines[1..<closingLine].contains("# pensieve: managed"), identity)
            XCTAssertFalse(h.vm.reconcileWaitingRemovals(context: h.base.context).hasFailures, identity)
            XCTAssertFalse(try h.base.files.entryExistsWithoutFollowingLinks(at: h.base.artifact(.codex)), identity)
            XCTAssertFalse(try h.base.files.entryExistsWithoutFollowingLinks(at: rule), identity)
            XCTAssertTrue(try h.vm.waitingRemovalStore.read().isEmpty, identity)
            XCTAssertFalse(h.base.files.fileExists(at: h.base.project.path + "/.pensieve-project"))
        }
    }

    func testEntryPathPermissionFailureIsReportedAndKeptForRetry() throws {
        let h = try WaitingRemovalHarness()
        defer { h.base.cleanup() }
        try h.deploy([.codex])
        try h.hideFolder()
        XCTAssertFalse(h.removeProject().hasFailures)
        try h.restoreFolder()
        let waiting = try h.vm.waitingRemovalStore.read()
        h.mapped.beforePathResolution = { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
        let result = h.vm.reconcileWaitingRemovals(context: h.base.context)
        XCTAssertTrue(result.hasFailures)
        XCTAssertTrue(result.operationFailures.contains { $0.contains(h.base.artifact(.codex)) })
        XCTAssertEqual(try h.vm.waitingRemovalStore.read(), waiting)
        XCTAssertTrue(h.base.files.isSymlink(at: h.base.artifact(.codex)))
        h.mapped.beforePathResolution = nil
        XCTAssertFalse(h.vm.reconcileWaitingRemovals(context: h.base.context).hasFailures)
        XCTAssertFalse(h.base.files.isSymlink(at: h.base.artifact(.codex)))
    }

    func testWaitingRequestsCoverAllCategoryAndIntentDeployPathsIncludingAlias() throws {
        let h = try WaitingRemovalHarness(platforms: [.claudeCode, .codex, .cursor])
        defer { h.base.cleanup() }
        try h.base.files.createDirectory(at: h.base.project.path)
        let alias = h.base.root + "/alias"
        try h.base.files.createSymlink(at: alias, pointingTo: h.base.project.path)
        h.base.otherProject.path = alias
        let category = try h.base.addCategory()
        category.projectKeys.append(h.base.otherProject.identityKey!)
        let direct = try h.base.addDirectSkill(platforms: [.codex, .cursor])
        XCTAssertFalse(h.base.category.reconcile(context: h.base.context).hasFailures)
        XCTAssertFalse(h.base.intent.reconcile(context: h.base.context).hasFailures)
        try h.recordProjectIdentity()
        let records = try h.base.deployState.read().records
        XCTAssertEqual(records.count, 8)
        // The independent owner is the real deployment output, without its derived evidence.
        try h.base.deployState.replaceAll([])
        let skills = [h.base.skill.directoryName: h.base.skill, direct.directoryName: direct]
        let entries = try records.map { record -> WaitingRemoval in
            let project = record.artifactPath.hasPrefix(alias + "/") ? h.base.otherProject : h.base.project
            return h.vm.waitingRemoval(skill: try XCTUnwrap(skills[record.slug]),
                platform: try XCTUnwrap(PlatformTarget(rawValue: record.platform)), project: project, source: "guard")
        }
        try h.vm.waitingRemovalStore.add(entries)
        var deleted: [String] = []
        h.mapped.beforeArtifactDeletion = { deleted.append($0) }
        XCTAssertFalse(h.vm.reconcileWaitingRemovals(context: h.base.context).hasFailures)
        XCTAssertTrue(deleted.isEmpty, "Every path deployed by either reconciler remains desired")
        for entry in entries { XCTAssertTrue(try h.base.files.entryExistsWithoutFollowingLinks(at: entry.artifactPath)) }
        XCTAssertTrue(try h.vm.waitingRemovalStore.read().isEmpty)
    }
}
