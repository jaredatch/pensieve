import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class WaitingRemovalSkillFailureTests: XCTestCase {
    func testUnrelatedUncheckableProjectGetsNoArtifactInspectionOrWaitingCandidate() throws {
        let h = try WaitingRemovalHarness(platforms: [.claudeCode, .codex, .cursor])
        defer { h.base.cleanup() }
        var inspections: [String] = []
        h.mapped.beforeProjectProbe = { path in
            if path == h.base.project.path { throw CocoaError(.fileReadNoPermission) }
        }
        h.mapped.beforeEntryTypeProbe = { path in
            if path.hasPrefix(h.base.project.path + "/") {
                inspections.append(path)
                throw CocoaError(.fileReadNoPermission)
            }
        }
        XCTAssertTrue(h.deleteSkill())
        XCTAssertTrue(inspections.isEmpty)
        XCTAssertTrue(try h.vm.waitingRemovalStore.read().isEmpty)
        XCTAssertFalse(h.library.deletionNotice?.message.contains(h.base.project.path) == true)
    }

    func testLibraryFailureAfterSavedRetirementKeepsWaitingAndRetiresDeferredState() throws {
        for phase in ["files", "row"] {
            let h = try WaitingRemovalHarness()
            defer { h.base.cleanup() }
            try h.deploy([.codex])
            try h.hideFolder()
            let failingStore = RecordingDeletionSkillStore()
            failingStore.bodies[h.base.skill.directoryName] = "# Body"
            failingStore.entries.insert(h.base.skill.directoryName)
            failingStore.deleteFailures.insert(h.base.skill.directoryName)
            let library = phase == "row" ? h.library : SkillLibraryViewModel(
                skillStore: failingStore,
                fileService: h.mapped, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir),
                manifestService: ManifestService(fileService: h.base.files), manifestRoot: h.base.root + "/store",
                notifier: {}
            )
            var saves = 0
            XCTAssertFalse(SkillDeletionFlow.delete(skill: h.base.skill, library: library, platformVM: h.vm,
                projects: [h.base.project, h.base.otherProject], context: h.base.context, persist: { context in
                    saves += 1
                    if phase == "row", saves == 2 { throw CocoaError(.fileWriteNoPermission) }
                    try context.save()
                }))
            let saved = ModelContext(h.base.context.container)
            XCTAssertEqual(try saved.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
            XCTAssertEqual(try saved.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
            XCTAssertEqual(try saved.fetchCount(FetchDescriptor<Skill>()), 1)
            XCTAssertEqual(try h.vm.waitingRemovalStore.read().map(\.artifactPath), [h.base.artifact(.codex)], phase)
            XCTAssertTrue(try h.base.deployState.read().records.isEmpty, phase)
            XCTAssertEqual(library.isWriteFenced(h.base.skill), phase == "row")
            try h.restoreFolder()
            XCTAssertFalse(h.vm.reconcileWaitingRemovals(context: saved).hasFailures)
            XCTAssertFalse(h.base.files.isSymlink(at: h.base.artifact(.codex)))
            XCTAssertTrue(try h.vm.waitingRemovalStore.read().isEmpty)
        }
    }

    func testMarkedCursorRuleWithOnlyRequestsOrLedgerIsNeverQueuedOrDeleted() throws {
        for evidence in ["request", "intent ledger", "category ledger"] {
            let h = try WaitingRemovalHarness(platforms: [.cursor])
            defer { h.base.cleanup() }
            try h.base.files.createDirectory(at: h.base.project.path)
            let path = h.vm.artifactPath(skill: h.base.skill, platform: .cursor, target: .project(h.base.project))
            let bytes = "---\n# pensieve: managed\n---\nTeammate rule"
            try h.base.files.writeFile(at: path, content: bytes)
            if evidence == "request" { try h.base.addIntent(platform: .cursor) } else if evidence == "intent ledger" {
                h.base.context.insert(IntentAssignment(skillID: h.base.skill.id,
                    platformRaw: PlatformTarget.cursor.rawValue, projectID: h.base.project.id))
            } else {
                h.base.context.insert(SkillProjectAssignment(skillID: h.base.skill.id,
                    projectID: h.base.project.id, platform: .cursor))
            }
            try h.base.context.save()
            try h.hideFolder()
            XCTAssertTrue(h.deleteSkill(), evidence)
            XCTAssertTrue(try h.vm.waitingRemovalStore.read().isEmpty, evidence)
            XCTAssertFalse(h.library.deletionNotice?.message.contains(h.base.project.path) == true)
            try h.restoreFolder()
            XCTAssertFalse(h.vm.reconcileWaitingRemovals(context: h.base.context).hasFailures)
            XCTAssertEqual(try h.base.files.readFile(at: path), bytes, evidence)
        }
    }

    func testFinalRecordRetirementWarningPreservesWaitingAndManifestNotice() throws {
        for clearNotice in [false, true] {
            let h = try WaitingRemovalHarness()
            defer { h.base.cleanup() }
            try h.deploy([.codex])
            try h.hideFolder()
            let manifest = RecordingDeletionManifest()
            manifest.failingWrites = [1, 2]
            let library = SkillLibraryViewModel(
                skillStore: SkillStore(fileService: h.mapped, baseDir: TestPaths.skillsDir),
                fileService: h.mapped, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir),
                manifestService: manifest, manifestRoot: h.base.root + "/store",
                notifier: {}
            )
            h.base.mapped.beforeDeployStateWrite = { _ in
                if clearNotice { library.deletionNotice = nil }
                throw CocoaError(.fileWriteNoPermission)
            }
            XCTAssertTrue(SkillDeletionFlow.delete(skill: h.base.skill, library: library, platformVM: h.vm,
                projects: [h.base.project, h.base.otherProject], context: h.base.context))
            let message = try XCTUnwrap(library.deletionNotice?.message)
            XCTAssertTrue(message.hasPrefix("Deleted “\(h.base.skill.name)”."), "clearNotice=\(clearNotice)")
            if !clearNotice {
                XCTAssertTrue(message.contains(h.base.project.name))
                XCTAssertTrue(message.contains(h.base.project.path))
                XCTAssertTrue(message.contains("will be removed when the folder is back"))
                XCTAssertTrue(message.contains("sync manifest couldn't be updated"))
            }
            XCTAssertTrue(message.contains("records couldn't be retired"))
            XCTAssertEqual(try h.vm.waitingRemovalStore.read().count, 1)
        }
    }
}
