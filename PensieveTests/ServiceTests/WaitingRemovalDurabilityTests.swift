import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class WaitingRemovalDurabilityTests: XCTestCase {
    func testWaitingWriteFailureRetainsSkillOrProjectAndAllSourceRecords() throws {
        for route in ["skill", "project"] {
            let h = try WaitingRemovalHarness()
            defer { h.base.cleanup() }
            try h.deploy([.codex])
            let category = try h.base.addCategory()
            XCTAssertFalse(h.base.category.reconcile(context: h.base.context).hasFailures)
            h.vm.deploy(skill: h.base.skill, platform: .codex, context: h.base.context)
            let userPath = h.vm.artifactPath(skill: h.base.skill, platform: .codex, target: .userWide)
            let before = try h.base.deployState.read()
            let intentKeys = try h.base.context.fetch(FetchDescriptor<MachineDeployIntent>()).map(\.key)
            let ledgerIDs = try h.base.context.fetch(FetchDescriptor<IntentAssignment>()).map(\.id)
            let categoryIDs = try h.base.context.fetch(FetchDescriptor<SkillProjectAssignment>()).map(\.id)
            try h.hideFolder()
            h.mapped.beforeFileWrite = { path in
                if path == h.storePath { throw CocoaError(.fileWriteNoPermission) }
            }
            if route == "skill" {
                XCTAssertFalse(h.deleteSkill())
                XCTAssertTrue(h.library.deletionNotice?.message.contains("kept") == true)
            } else { XCTAssertTrue(h.removeProject().hasFailures) }
            let saved = ModelContext(h.base.context.container)
            XCTAssertEqual(try saved.fetchCount(FetchDescriptor<Skill>()), 1)
            XCTAssertEqual(try saved.fetchCount(FetchDescriptor<Project>()), 2)
            XCTAssertEqual(try saved.fetch(FetchDescriptor<MachineDeployIntent>()).map(\.key), intentKeys)
            XCTAssertEqual(try saved.fetch(FetchDescriptor<IntentAssignment>()).map(\.id), ledgerIDs)
            XCTAssertEqual(try saved.fetch(FetchDescriptor<SkillProjectAssignment>()).map(\.id), categoryIDs)
            XCTAssertEqual(try h.base.deployState.read(), before)
            XCTAssertEqual(category.skillSlugs, [h.base.skill.directoryName])
            XCTAssertEqual(category.projectKeys, [h.base.project.identityKey!])
            XCTAssertTrue(h.mapped.isSymlink(at: userPath))
            XCTAssertTrue(h.mapped.fileExists(at: h.base.skill.canonicalPath(skillsDirectory: TestPaths.skillsDir)))
            XCTAssertFalse(h.base.files.fileExists(at: h.storePath))
        }
    }

    func testMalformedAndNewerWaitingFilesPauseAndNeverChange() throws {
        for content in ["broken json", #"{"schema_version":2,"removals":[]}"#,
                        #"{"schema_version":1e40,"removals":[]}"#] {
            let h = try WaitingRemovalHarness()
            defer { h.base.cleanup() }
            try h.deploy([.codex])
            try h.base.files.writeFile(at: h.storePath, content: content)
            let state = try h.base.deployState.read()
            XCTAssertTrue(h.vm.reconcileWaitingRemovals(context: h.base.context).hasFailures)
            XCTAssertTrue(h.base.files.isSymlink(at: h.base.artifact(.codex)))
            try h.hideFolder()
            XCTAssertFalse(h.deleteSkill())
            XCTAssertTrue(h.removeProject().hasFailures)
            XCTAssertEqual(try h.base.files.readFile(at: h.storePath), content)
            XCTAssertEqual(try h.base.deployState.read(), state)
            XCTAssertEqual(try h.base.context.fetchCount(FetchDescriptor<Skill>()), 1)
            XCTAssertEqual(try h.base.context.fetchCount(FetchDescriptor<Project>()), 2)
            XCTAssertEqual(try h.base.context.fetchCount(FetchDescriptor<IntentAssignment>()), 1)
        }
    }

    func testNewerEntryAtSamePathSurvivesOlderPassAndIdempotentCreation() throws {
        let h = try WaitingRemovalHarness()
        defer { h.base.cleanup() }
        try h.deploy([.codex])
        try h.hideFolder()
        XCTAssertFalse(h.removeProject().hasFailures)
        let old = try XCTUnwrap(h.vm.waitingRemovalStore.read().first)
        try h.vm.waitingRemovalStore.add([h.entry(source: old.source)])
        XCTAssertEqual(try h.vm.waitingRemovalStore.read().map(\.id), [old.id])
        try h.restoreFolder()
        let newer = h.entry(source: "new source")
        h.mapped.beforeArtifactDeletion = { path in
            if path == newer.artifactPath { try h.vm.waitingRemovalStore.add([newer]) }
        }
        XCTAssertFalse(h.vm.reconcileWaitingRemovals(context: h.base.context).hasFailures)
        XCTAssertEqual(try h.vm.waitingRemovalStore.read(), [newer])
        XCTAssertFalse(h.base.files.isSymlink(at: newer.artifactPath))
        h.mapped.beforeArtifactDeletion = nil
        XCTAssertFalse(h.vm.reconcileWaitingRemovals(context: h.base.context).hasFailures)
        XCTAssertTrue(try h.vm.waitingRemovalStore.read().isEmpty)
    }

    func testArtifactAndRetirementFailuresKeepWaitingForSafeRetry() throws {
        for phase in ["ownership", "delete", "waiting save"] {
            let h = try WaitingRemovalHarness()
            defer { h.base.cleanup() }
            try h.deploy([.codex])
            try h.hideFolder()
            XCTAssertFalse(h.removeProject().hasFailures)
            try h.restoreFolder()
            let waiting = try h.vm.waitingRemovalStore.read()
            if phase == "ownership" {
                h.mapped.beforeSymlinkRead = { _ in throw CocoaError(.fileReadNoPermission) }
            } else if phase == "delete" {
                h.mapped.beforeArtifactDeletion = { _ in throw CocoaError(.fileWriteNoPermission) }
            } else {
                h.mapped.beforeFileWrite = { path in
                    if path == h.storePath { throw CocoaError(.fileWriteNoPermission) }
                }
            }
            XCTAssertTrue(h.vm.reconcileWaitingRemovals(context: h.base.context).hasFailures)
            XCTAssertEqual(try h.vm.waitingRemovalStore.read(), waiting)
            XCTAssertEqual(h.base.files.isSymlink(at: h.base.artifact(.codex)), phase != "waiting save")
            h.mapped.beforeSymlinkRead = nil
            h.mapped.beforeArtifactDeletion = nil
            h.mapped.beforeFileWrite = nil
            XCTAssertFalse(h.vm.reconcileWaitingRemovals(context: h.base.context).hasFailures)
            XCTAssertFalse(h.base.files.isSymlink(at: h.base.artifact(.codex)))
            XCTAssertTrue(try h.vm.waitingRemovalStore.read().isEmpty)
        }
    }
}
