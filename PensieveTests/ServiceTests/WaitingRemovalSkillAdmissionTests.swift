import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class WaitingRemovalSkillAdmissionTests: XCTestCase {
    func testNeverDeployedMissingProjectDoesNotQueueOrAppearInNoticeOrProbes() throws {
        let h = try WaitingRemovalHarness(platforms: [.claudeCode, .codex, .cursor])
        defer { h.base.cleanup() }
        var probes: [String] = []
        h.mapped.beforeProjectProbe = { probes.append($0) }
        XCTAssertTrue(h.deleteSkill())
        XCTAssertTrue(try h.vm.waitingRemovalStore.read().isEmpty)
        XCTAssertFalse(h.library.deletionNotice?.message.contains(h.base.project.name) == true)
        XCTAssertFalse(h.library.deletionNotice?.message.contains(h.base.project.path) == true)
        XCTAssertTrue(probes.isEmpty)
    }

    func testUnrelatedMissingProjectDoesNotBlockDeletionUnderUnreadableDeploymentState() throws {
        for content in ["broken", #"{"schema_version":999,"records":[]}"#] {
            let h = try WaitingRemovalHarness()
            defer { h.base.cleanup() }
            try h.base.files.writeFile(at: h.base.root + "/support/deploy-state.json", content: content)
            XCTAssertTrue(h.deleteSkill(), content)
            XCTAssertEqual(try h.base.context.fetchCount(FetchDescriptor<Skill>()), 0)
            XCTAssertTrue(try h.vm.waitingRemovalStore.read().isEmpty)
            XCTAssertEqual(try h.base.files.readFile(at: h.base.root + "/support/deploy-state.json"), content)
        }
    }

    func testEachLocalEvidenceSourceSelectsOnlyItsAgentAndFolder() throws {
        for source in ["category", "intent", "local request", "state", "history", "remote request"] {
            for platform in [PlatformTarget.claudeCode, .codex, .cursor] where source != "history" || platform == .cursor {
                let h = try WaitingRemovalHarness(platforms: [.claudeCode, .codex, .cursor])
                defer { h.base.cleanup() }
                let path = h.vm.artifactPath(skill: h.base.skill, platform: platform, target: .project(h.base.project))
                switch source {
                case "category": h.base.context.insert(SkillProjectAssignment(
                    skillID: h.base.skill.id, projectID: h.base.project.id, platform: platform))
                case "intent": h.base.context.insert(IntentAssignment(
                    skillID: h.base.skill.id, platformRaw: platform.rawValue, projectID: h.base.project.id))
                case "local request": try h.base.addIntent(platform: platform)
                case "remote request": h.base.context.insert(MachineDeployIntent(machineID: UUID().uuidString,
                    skillSlug: h.base.skill.directoryName, platformRaw: platform.rawValue,
                    projectKey: h.base.project.identityKey))
                case "history": h.base.context.insert(DeployRecord(skillID: h.base.skill.id, platform: .cursor,
                    targetPath: path, contentHash: "local", projectID: h.base.project.id))
                default: try h.base.deployState.upsert(DeployStateRecord(slug: h.base.skill.directoryName,
                    platform: platform.rawValue, scope: "project", projectIdentityKey: h.base.project.identityKey,
                    artifactPath: path, recordedAt: "before"))
                }
                try h.base.context.save()
                var probes: [String] = []
                h.mapped.beforeProjectProbe = { probes.append($0) }
                XCTAssertTrue(h.deleteSkill(), "\(source)/\(platform)")
                let admitted = source != "remote request"
                XCTAssertEqual(try h.vm.waitingRemovalStore.read().map(\.artifactPath), admitted ? [path] : [])
                XCTAssertEqual(probes, admitted ? [h.base.project.path] : [])
                XCTAssertEqual(h.library.deletionNotice?.message.contains(h.base.project.path) == true, admitted)
                XCTAssertFalse(h.library.deletionNotice?.message.contains(h.base.otherProject.path) == true)
            }
        }
    }

    func testAvailableRemovalFailureKeepsUnavailableRecordsAndOnlyPreexistingWaitingEntries() throws {
        for preexisting in [false, true] {
            let h = try WaitingRemovalHarness()
            defer { h.base.cleanup() }
            try h.deploy([.codex])
            try h.base.addIntent(platform: .codex, project: h.base.otherProject)
            XCTAssertFalse(h.base.intent.reconcile(context: h.base.context).hasFailures)
            h.base.context.insert(SkillProjectAssignment(skillID: h.base.skill.id,
                projectID: h.base.project.id, platform: .codex))
            try h.base.context.save()
            try h.hideFolder()
            let before = try h.base.deployState.read()
            let ledger = try h.base.context.fetch(FetchDescriptor<IntentAssignment>()).map(\.id)
            let categoryLedger = try h.base.context.fetch(FetchDescriptor<SkillProjectAssignment>()).map(\.id)
            let old = h.entry(source: "skill:\(h.base.skill.id)")
            if preexisting { try h.vm.waitingRemovalStore.add([old]) }
            h.mapped.beforeArtifactDeletion = { path in
                if path == h.base.artifact(.codex, project: h.base.otherProject) {
                    throw CocoaError(.fileWriteNoPermission)
                }
            }
            XCTAssertFalse(h.deleteSkill())
            XCTAssertEqual(try h.base.deployState.read(), before)
            let saved = ModelContext(h.base.context.container)
            XCTAssertEqual(try saved.fetch(FetchDescriptor<IntentAssignment>()).map(\.id), ledger)
            XCTAssertEqual(try saved.fetch(FetchDescriptor<SkillProjectAssignment>()).map(\.id), categoryLedger)
            XCTAssertEqual(try h.base.context.fetchCount(FetchDescriptor<Skill>()), 1)
            XCTAssertEqual(try h.vm.waitingRemovalStore.read(), preexisting ? [old] : [])
            h.mapped.beforeArtifactDeletion = nil
            XCTAssertTrue(h.deleteSkill())
            XCTAssertTrue(try h.base.deployState.read().records.isEmpty)
            XCTAssertEqual(try h.vm.waitingRemovalStore.read().count, 1)
        }
    }
}
