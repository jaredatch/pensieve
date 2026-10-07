import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class WaitingRemovalLifecycleTests: XCTestCase {
    func testSkillDeletionWaitsAcrossRelaunchThenLaunchRemovesRestoredLink() throws {
        let h = try WaitingRemovalHarness(persistent: true)
        defer { h.base.cleanup() }
        try h.deploy([.codex])
        let path = h.base.artifact(.codex)
        try h.hideFolder()
        XCTAssertTrue(h.deleteSkill())
        XCTAssertEqual(try h.base.context.fetchCount(FetchDescriptor<Skill>()), 0)
        XCTAssertEqual(try h.base.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
        XCTAssertEqual(try h.base.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
        XCTAssertTrue(try h.base.deployState.read().records.isEmpty)
        XCTAssertTrue(h.library.deletionNotice?.message.contains(h.base.project.path) == true)
        XCTAssertTrue(h.library.deletionNotice?.message.contains("will be removed when the folder is back") == true)
        let waiting = try h.vm.waitingRemovalStore.read()
        XCTAssertEqual(waiting.map(\.artifactPath), [path])
        let bytes = try h.base.files.readData(at: h.storePath)
        let container = try AppRuntime.makeContainer(configuration:
            ModelConfiguration(url: URL(fileURLWithPath: h.base.root + "/removal.sqlite")))
        let context = ModelContext(container)
        let store = WaitingRemovalStore(fileService: h.mapped, appSupportDir: h.base.root + "/support")
        let reconciler = WaitingRemovalReconciler(store: store, fileService: h.mapped, platformVM: h.vm,
            machineIdentity: ProjectIntentIdentityStub(id: ProjectIntentHarness.localID))
        XCTAssertEqual(try store.read(), waiting)
        XCTAssertFalse(reconciler.reconcile(context: context).hasFailures)
        XCTAssertEqual(try h.base.files.readData(at: h.storePath), bytes)
        try h.restoreFolder()
        XCTAssertFalse(h.converge().contains { $0.contains("Failed") || $0.contains(":1:skipped") })
        XCTAssertFalse(try h.base.files.entryExistsWithoutFollowingLinks(at: path))
        XCTAssertTrue(try store.read().isEmpty)
    }

    func testForeignOccupantsRetireWaitingWithoutChangingTheirContents() throws {
        for shape in ["link", "file", "folder", "absent"] {
            let h = try WaitingRemovalHarness()
            defer { h.base.cleanup() }
            try h.deploy([.codex])
            let path = h.base.artifact(.codex)
            try h.hideFolder()
            XCTAssertTrue(h.deleteSkill())
            try h.restoreFolder()
            try h.base.files.deleteFile(at: path)
            if shape == "link" { try h.base.files.createSymlink(at: path, pointingTo: h.base.otherProject.path) }
            if shape == "file" { try h.base.files.writeFile(at: path, content: "Keep this file") }
            if shape == "folder" { try h.base.files.writeFile(at: path + "/notes", content: "Keep these notes") }
            _ = h.converge()
            XCTAssertTrue(try h.vm.waitingRemovalStore.read().isEmpty, shape)
            XCTAssertEqual(try h.base.files.entryExistsWithoutFollowingLinks(at: path), shape != "absent", shape)
            if shape == "link" { XCTAssertEqual(try h.base.files.symlinkTarget(at: path), h.base.otherProject.path) }
            if shape == "file" { XCTAssertEqual(try h.base.files.readFile(at: path), "Keep this file") }
            if shape == "folder" { XCTAssertEqual(try h.base.files.readFile(at: path + "/notes"), "Keep these notes") }
        }
    }

    func testLegacyCursorDigestRemovesOnlyExactBytesAfterSourceDeletion() throws {
        for replacement in ["exact", "edited", "source unavailable", "marked without source"] {
            let h = try WaitingRemovalHarness(platforms: [.cursor])
            defer { h.base.cleanup() }
            try h.deploy([.cursor])
            let path = h.vm.artifactPath(skill: h.base.skill, platform: .cursor, target: .project(h.base.project))
            let legacy = "---\nalwaysApply: false\n---\n\n# Body\n"
            let edited = "---\nalwaysApply: false\n---\n\n# Edit\n"
            let marked = "---\n# pensieve: managed\nalwaysApply: false\n---\n\n# Body\n"
            try h.base.files.writeFile(at: path, content: replacement == "marked without source" ? marked : legacy)
            try h.hideFolder()
            let sourceUnavailable = replacement == "source unavailable" || replacement == "marked without source"
            if sourceUnavailable {
                try h.base.files.deleteFile(at: h.base.root + "/store/skills/" + h.base.skill.directoryName + "/SKILL.md")
            }
            XCTAssertTrue(h.deleteSkill())
            let waiting = try XCTUnwrap(h.vm.waitingRemovalStore.read().first)
            XCTAssertEqual(waiting.legacyFingerprint == nil, sourceUnavailable)
            try h.restoreFolder()
            if replacement == "edited" { try h.base.files.writeFile(at: path, content: edited) }
            _ = h.converge()
            XCTAssertTrue(try h.vm.waitingRemovalStore.read().isEmpty)
            let kept = replacement == "edited" || replacement == "source unavailable"
            XCTAssertEqual(h.base.files.fileExists(at: path), kept)
            if kept {
                XCTAssertEqual(try h.base.files.readFile(at: path), replacement == "edited" ? edited : legacy)
            }
        }
    }

    func testUncheckableSkillFolderWaitsAndLaterCleansItsLink() throws {
        let h = try WaitingRemovalHarness()
        defer { h.base.cleanup() }
        try h.deploy([.codex])
        h.mapped.beforeProjectProbe = { path in
            if path == h.base.project.path { throw CocoaError(.fileReadNoPermission) }
        }
        XCTAssertTrue(h.deleteSkill())
        XCTAssertTrue(h.library.deletionNotice?.message.contains(h.base.project.path) == true)
        XCTAssertEqual(try h.vm.waitingRemovalStore.read().count, 1)
        XCTAssertTrue(h.base.files.isSymlink(at: h.base.artifact(.codex)))
        XCTAssertFalse(h.vm.reconcileWaitingRemovals(context: h.base.context).hasFailures)
        XCTAssertEqual(try h.vm.waitingRemovalStore.read().count, 1)
        h.mapped.beforeProjectProbe = nil
        _ = h.converge()
        XCTAssertFalse(h.base.files.isSymlink(at: h.base.artifact(.codex)))
        XCTAssertTrue(try h.vm.waitingRemovalStore.read().isEmpty)
    }
}
