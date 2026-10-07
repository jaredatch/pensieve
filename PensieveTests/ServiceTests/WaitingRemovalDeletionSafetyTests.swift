import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class WaitingRemovalDeletionSafetyTests: XCTestCase {
    func testSkillDeletionLosingFolderDuringClassificationKeepsSkillAndEvidenceForRetry() throws {
        let h = try WaitingRemovalHarness()
        defer { h.base.cleanup() }
        try h.deploy([.codex])
        let state = try h.base.deployState.read()
        var lost = false
        h.mapped.beforeEntryTypeProbe = { path in
            if path == h.base.artifact(.codex), !lost { try h.hideFolder(); lost = true }
        }
        XCTAssertFalse(h.deleteSkill(), "Folder loss after admission must keep the skill")
        XCTAssertEqual(try h.base.context.fetchCount(FetchDescriptor<Skill>()), 1)
        XCTAssertEqual(try h.base.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 1)
        XCTAssertEqual(try h.base.context.fetchCount(FetchDescriptor<IntentAssignment>()), 1)
        XCTAssertEqual(try h.base.deployState.read(), state)
        XCTAssertTrue(try h.vm.waitingRemovalStore.read().isEmpty)
        h.mapped.beforeEntryTypeProbe = nil
        XCTAssertTrue(h.deleteSkill())
        XCTAssertEqual(try h.vm.waitingRemovalStore.read().count, 1)
        try h.restoreFolder()
        XCTAssertFalse(h.vm.reconcileWaitingRemovals(context: h.base.context).hasFailures)
        XCTAssertFalse(h.base.files.isSymlink(at: h.base.artifact(.codex)))
    }

    func testProjectRemovalLosingFolderDuringClassificationKeepsRegistrationAndEvidenceForRetry() throws {
        let h = try WaitingRemovalHarness()
        defer { h.base.cleanup() }
        try h.deploy([.codex])
        let state = try h.base.deployState.read()
        var lost = false
        h.mapped.beforeEntryTypeProbe = { path in
            if path == h.base.artifact(.codex), !lost { try h.hideFolder(); lost = true }
        }
        XCTAssertTrue(h.removeProject().hasFailures, "Folder loss during preparation must keep the project")
        XCTAssertEqual(try h.base.context.fetchCount(FetchDescriptor<Project>()), 2)
        XCTAssertEqual(try h.base.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 1)
        XCTAssertEqual(try h.base.context.fetchCount(FetchDescriptor<IntentAssignment>()), 1)
        XCTAssertEqual(try h.base.deployState.read(), state)
        h.mapped.beforeEntryTypeProbe = nil
        XCTAssertFalse(h.removeProject().hasFailures)
        XCTAssertEqual(try h.vm.waitingRemovalStore.read().count, 1)
        try h.restoreFolder()
        XCTAssertFalse(h.vm.reconcileWaitingRemovals(context: h.base.context).hasFailures)
        XCTAssertFalse(h.base.files.isSymlink(at: h.base.artifact(.codex)))
    }

    func testMixedSkillDeletionWritesAvailableBatchThenWaitingRecordsAfterDeletion() throws {
        let h = try WaitingRemovalHarness(platforms: [.claudeCode, .codex])
        defer { h.base.cleanup() }
        try h.deploy([.codex])
        for platform in [PlatformTarget.claudeCode, .codex] {
            try h.base.addIntent(platform: platform, project: h.base.otherProject)
        }
        XCTAssertFalse(h.base.intent.reconcile(context: h.base.context).hasFailures)
        try h.hideFolder()
        var writes: [Data] = []
        var skillCounts: [Int] = []
        h.base.mapped.beforeDeployStateWrite = { path in
            writes.append(try h.base.files.readData(at: path))
            skillCounts.append(try ModelContext(h.base.context.container).fetchCount(FetchDescriptor<Skill>()))
        }
        XCTAssertTrue(h.deleteSkill())
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(skillCounts, [1, 0], "Waiting records retire only after the skill row was deleted")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let beforeSecondWrite = try XCTUnwrap(writes.dropFirst().first)
        XCTAssertEqual(try decoder.decode(DeployState.self, from: beforeSecondWrite).records.map(\.artifactPath),
                       [h.base.artifact(.codex)], "The first write keeps the missing folder's record")
        XCTAssertTrue(try h.base.deployState.read().records.isEmpty)
        XCTAssertEqual(try h.vm.waitingRemovalStore.read().count, 1)
        for platform in [PlatformTarget.claudeCode, .codex] {
            XCTAssertFalse(h.base.files.isSymlink(at: h.base.artifact(platform, project: h.base.otherProject)))
        }
    }

    func testKeptSkillRecordWarningUsesDeletionOutcomeForFilesAndRowFailures() throws {
        for phase in ["files", "row"] {
            let h = try WaitingRemovalHarness()
            defer { h.base.cleanup() }
            try h.deploy([.codex])
            try h.hideFolder()
            let failing = RecordingDeletionSkillStore()
            failing.entries.insert(h.base.skill.directoryName)
            failing.deleteFailures.insert(h.base.skill.directoryName)
            let library = phase == "row" ? h.library : SkillLibraryViewModel(skillStore: failing,
                fileService: h.mapped, manifestService: ManifestService(fileService: h.base.files),
                manifestRoot: h.base.root + "/store", notifier: {})
            h.base.mapped.beforeDeployStateWrite = { _ in throw CocoaError(.fileWriteNoPermission) }
            var saves = 0
            XCTAssertFalse(SkillDeletionFlow.delete(skill: h.base.skill, library: library, platformVM: h.vm,
                projects: [h.base.project], context: h.base.context, persist: { context in
                    saves += 1
                    if phase == "row", saves == 2 { throw CocoaError(.fileWriteNoPermission) }
                    try context.save()
                }))
            let message = try XCTUnwrap(library.deletionNotice?.message)
            XCTAssertFalse(message.contains("Deleted"), "A kept skill never reports deletion: \(phase)")
            if phase == "row" {
                XCTAssertTrue(message.hasPrefix("Removed “"), "Files removed with a retained row must say so first")
                XCTAssertFalse(message.contains("was kept"), "A retained row is not a kept skill directory")
            } else {
                XCTAssertTrue(message.hasPrefix("The skill “"))
            }
            XCTAssertTrue(message.contains(h.base.skill.name))
            XCTAssertTrue(message.contains("records couldn't be retired"))
            XCTAssertEqual(try h.vm.waitingRemovalStore.read().count, 1)
            XCTAssertEqual(try h.base.context.fetchCount(FetchDescriptor<Skill>()), 1)
        }
    }

    func testCleanupNamesEveryFailedEvidenceRead() throws {
        for (failure, available) in [("history", false), ("local", false), ("history", true)] {
            let h = try WaitingRemovalHarness(platforms: [.cursor])
            defer { h.base.cleanup() }
            if available {
                try h.base.files.createDirectory(at: h.base.project.path)
                let path = h.vm.artifactPath(skill: h.base.skill, platform: .cursor, target: .project(h.base.project))
                try h.base.files.writeFile(at: path, content: "---\n# pensieve: managed\n---\nRule")
            }
            try h.base.files.writeFile(at: h.base.root + "/support/deploy-state.json", content: "corrupt")
            let result = h.vm.removeAllDeploys(skill: h.base.skill, projects: [h.base.project], localProjectEvidence: {
                let error = NSError(domain: "Evidence", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "\(failure) evidence refused"])
                if failure == "local" { throw error }
                return SkillProjectDeployEvidence(paths: [], historyFailure: error)
            }).batch
            let message = result.readFailures.map(\.message).joined(separator: " ")
            XCTAssertTrue(message.contains("deploy state unreadable"), failure)
            XCTAssertTrue(message.contains("\(failure) evidence refused"), failure)
            XCTAssertEqual(result.readFailures.count, 2, "Neither evidence failure may hide the other")
            XCTAssertEqual(try h.base.context.fetchCount(FetchDescriptor<Skill>()), 1)
        }
    }
}
