import AppKit
import SwiftData
import SwiftUI
import WebKit
import XCTest
@testable import Pensieve

/// Each test owns one user-visible hold contract at the real queue/disk/rebuild boundary.
@MainActor
final class SkillRenameHoldTests: XCTestCase {
    func testARefusedRenameThatCantMoveBackLeavesBothRecordsAloneAtTheNextSync() async throws {
        for arm in ["taken", "unrewritable", "unknown-date"] {
            let h = try SkillRenameTakeoverFixture(record: false, leftovers: false, distinctRecords: true)
            defer { h.cleanup() }
            let before = try await h.beginHold(unreadableDate: arm == "unknown-date",
                unrewritable: arm == "unrewritable", keepOldFolder: true)
            let bytes = arm == "unknown-date" ? nil : try h.files.readData(at: h.root + "/manifest/skills/zulu.yaml")
            XCTAssertTrue(h.library.error?.hasSuffix(SkillRenameTakeoverFixture.holdSentence) == true)
            XCTAssertEqual(h.skill.directoryName, "zulu")
            try h.syncHeld()
            try h.assertGuarded(before, bytes: bytes)
            XCTAssertEqual(h.skill.tags, ["own"])
            XCTAssertEqual(h.skill.scope, .project)
            XCTAssertEqual(h.skill.createdAt, h.own.createdAt)
        }
    }

    func testChangesToAHeldSkillStayOnThisMac() async throws {
        let reader = RecordingSaveManifest()
        let h = try SkillRenameTakeoverFixture(record: false, leftovers: false,
            queueManifest: reader, distinctRecords: true)
        defer { h.cleanup() }
        let before = try await h.beginHold(queuedTags: true)
        try h.assertGuarded(before)
        XCTAssertEqual(h.skill.tags, ["queued"])
        XCTAssertTrue(h.library.error?.hasSuffix(SkillRenameTakeoverFixture.holdSentence) == true)
        h.library.updateMetadata(h.skill, tags: ["latest"], scope: .project, context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.library.error, CollisionCreateFixture.message("zulu"))
        h.library.updateMetadata(h.skill, tags: ["latest"], scope: .user, context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.library.error, CollisionCreateFixture.message("zulu"))
        let members = h.goneCategory.skillSlugs
        CategoryStore(manifestSaves: h.saves).setSkill(h.skill, inCategory: h.goneCategory, assigned: true, context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.goneCategory.skillSlugs, members)
        XCTAssertTrue(h.saves.categoryNotice?.entries.contains {
            $0.text.contains(CollisionCreateFixture.message("zulu"))
        } == true)
        reader.failingSnapshots = .max
        XCTAssertFalse(StoreRebuildService(manifestService: reader).rebuild(fromRoot: h.root,
            context: h.context).ingestIncomplete)
        reader.failingSnapshots = 0
        try h.syncHeld()
        try h.assertGuarded(before)
        XCTAssertEqual(h.skill.tags, ["latest"])
        XCTAssertEqual(h.skill.scope, .user)
    }

    func testRenamingAHeldSkillToAFreeNameTakesItsOwnRecordAlong() async throws {
        let h = try SkillRenameTakeoverFixture(record: false, leftovers: false, distinctRecords: true)
        defer { h.cleanup() }
        let before = try await h.beginHold()
        await h.editHeld()
        XCTAssertTrue(h.renameHeld(), h.library.error ?? "")
        await h.saves.waitUntilIdle()
        try h.syncHeld()
        try h.assertPublished("free")
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root).skills.first { $0.slug == "zulu" },
            before.skills.first { $0.slug == "zulu" })
    }

    func testDeletingAHeldSkillKeepsTheOtherMacsRecord() async throws {
        for restart in [false, true] {
            let h = try SkillRenameTakeoverFixture(record: false, leftovers: false, distinctRecords: true, persistent: true)
            defer { h.cleanup() }
            let before = try await h.beginHold()
            let held = restart ? try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath)) : nil
            defer { held?.release() }
            XCTAssertTrue(h.deleteHeld(), h.library.deletionNotice?.message ?? "")
            if let held {
                await TestWait.until(failureMessage: "Deletion never waited on sync.lock") { h.saves.isWaiting }
                await h.quitWaiting(release: held)
                try await h.reopen(expectSkill: false)
            }
            await h.saves.waitUntilIdle()
            try h.syncHeld()
            let disk = try h.manifest.read(fromRoot: h.root)
            XCTAssertFalse(disk.skills.contains { $0.slug == "alpha" })
            XCTAssertEqual(disk.skills.first { $0.slug == "zulu" }, before.skills.first { $0.slug == "zulu" })
            XCTAssertFalse(disk.categories.contains { $0.skillSlugs.contains("alpha") })
            XCTAssertFalse(disk.deployIntents.contains { $0.skillSlug == "alpha" })
            XCTAssertEqual(disk.categories.first { $0.name == "Gone" }, before.categories.first { $0.name == "Gone" })
            XCTAssertEqual(disk.deployIntents.filter { $0.skillSlug == "zulu" },
                before.deployIntents.filter { $0.skillSlug == "zulu" })
        }
    }

    func testAHeldRenameFinishesWhenTheOtherMacsRecordLeaves() async throws {
        let h = try SkillRenameTakeoverFixture(record: false, leftovers: false, distinctRecords: true)
        defer { h.cleanup() }
        let before = try await h.beginHold()
        try h.syncHeld()
        try h.assertGuarded(before)
        await h.editHeld()
        var disk = try h.manifest.read(fromRoot: h.root)
        disk.skills.removeAll { $0.slug == "zulu" }
        try h.manifest.write(disk, toRoot: h.root)
        try h.syncHeld()
        try h.assertPublished("zulu")
        h.library.updateMetadata(h.skill, tags: ["published"], scope: .user, context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertNil(h.library.error)
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root).skills.first { $0.slug == "zulu" }?.tags, ["published"])
    }

    func testAnImportOrDeploymentChangeLeavesAHeldSkillsRecordsAlone() async throws {
        let h = try SkillRenameTakeoverFixture(record: false, leftovers: false, distinctRecords: true)
        defer { h.cleanup() }
        let before = try await h.beginHold()
        let importer = ImportViewModel(scanner: TestPaths.scanner, skillStore: h.store,
            lockPath: h.lockPath, manifestService: h.manifest, manifestRoot: h.root)
        importer.discoveredSkills = [DiscoveredSkill(name: "Imported", body: "Imported body", sourcePlatform: "folder",
            sourcePath: h.root + "/source")]
        importer.selectedSkills = [h.root + "/source"]
        _ = importer.importSelected(context: h.context)
        XCTAssertEqual(importer.importedSkillCount, 1, importer.error ?? "")
        try h.assertGuarded(before)
        let dependencies = DeployIntentDependencies.live(
            identity: MachineIdentity(fileService: h.files, appSupportDir: (h.lockPath as NSString).deletingLastPathComponent),
            stateService: InertMachineStateService(), root: h.root, lockPath: h.lockPath,
            notifier: SyncStateNotifier.suppressed, reconcile: { _ in BatchResult() })
        try DeployMutationService(platformVM: h.platform, dependencies: dependencies).setRemote(true,
            machineID: h.peer, projectKey: nil, skill: h.other, platform: .claudeCode, context: h.context)
        let after = try h.manifest.read(fromRoot: h.root)
        XCTAssertTrue(after.deployIntents.contains { $0.skillSlug == "other" && $0.machineID == h.peer })
        try h.assertGuarded(before)
    }

    func testAMoveBackWhoseUndoFailsEndsUnderTheOldName() async throws {
        let faults = RenameHoldFileFaults()
        let h = try SkillRenameTakeoverFixture(record: false, leftovers: false, distinctRecords: true, faults: faults)
        defer { h.cleanup() }
        let expectedDraft = h.library.editorBody(for: h.skill) + "\nUnsaved draft."
        XCTAssertTrue(h.rename())
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { held.release() }
        h.library.noteEditorChanged(h.skill, body: h.library.editorBody(for: h.skill) + "\nUnsaved draft.")
        let (window, editor) = try await openEditor(h)
        defer { window.contentView = nil; window.close() }
        h.library.updateMetadata(h.skill, tags: ["queued"], scope: .project, context: h.context)
        try h.arrivePeer()
        let peer = try h.files.readData(at: h.root + "/manifest/skills/zulu.yaml")
        failMovedBackWrite(h, faults: faults)
        held.release()
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.skill.directoryName, "alpha")
        XCTAssertEqual(h.skill.name, "Alpha")
        let shown = await TestWait.waitForEditorText(expectedDraft, in: editor,
            timeout: .seconds(TestWait.hostedActionTimeoutSeconds))
        XCTAssertEqual(shown, expectedDraft)
        try assertMovedBackAssignments(h)
        XCTAssertTrue(h.library.editorBody(for: h.skill).contains("Unsaved draft."))
        XCTAssertTrue(h.library.hasUnsavedChanges(for: h.skill))
        XCTAssertEqual(SkillParser.parse(h.library.editorBody(for: h.skill)).name, "Alpha")
        XCTAssertNotNil(h.library.error)
        XCTAssertFalse(h.library.error?.contains("still under") == true)
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root).skills.first { $0.slug == "alpha" }?.tags, ["queued"])
        h.library.updateMetadata(h.skill, tags: ["later"], scope: .project, context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root).skills.first { $0.slug == "alpha" }?.tags, ["later"])
        let link = h.projects[0].path + "/.claude/skills/alpha"
        XCTAssertEqual(try h.files.symlinkTarget(at: link), h.store.baseDir + "/alpha")
        try h.syncHeld()
        XCTAssertEqual(try h.files.readData(at: h.root + "/manifest/skills/zulu.yaml"), peer)
    }

    private func openEditor(_ h: SkillRenameTakeoverFixture) async throws -> (NSWindow, WKWebView) {
        let host = NSHostingView(rootView: SkillEditorView(skill: h.skill, library: h.library))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = host
        do { return (window, try await TestWait.waitForEditor(in: host)) } catch {
            window.contentView = nil
            window.close()
            throw error
        }
    }

    private func failMovedBackWrite(_ h: SkillRenameTakeoverFixture, faults: RenameHoldFileFaults) {
        faults.beforeWrite = { path in
            guard path == h.store.baseDir + "/alpha/SKILL.md" else { return }
            faults.beforeWrite = nil
            // Fail the file step after moving back, then occupy the inverse's destination.
            try h.files.createDirectory(at: h.store.baseDir + "/zulu")
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private func assertMovedBackAssignments(_ h: SkillRenameTakeoverFixture) throws {
        XCTAssertEqual(SkillParser.parse(try h.store.readBody(directoryName: "alpha")).name, "Alpha")
        let disk = try h.manifest.read(fromRoot: h.root)
        let window = try h.manifest.snapshot(from: h.context)
        XCTAssertEqual(window.categories.sorted { $0.name < $1.name }, disk.categories.sorted { $0.name < $1.name })
        func key(_ intent: DeployIntentRecord) -> String {
            [intent.machineID, intent.skillSlug, intent.platformRaw, intent.projectKey ?? ""].joined(separator: "|")
        }
        XCTAssertEqual(window.deployIntents.sorted { key($0) < key($1) }, disk.deployIntents.sorted { key($0) < key($1) })
    }

    func testARefusedRenameIsStillGuardedAfterItsRebuildFails() async throws {
        let reader = RecordingSaveManifest()
        let h = try SkillRenameTakeoverFixture(record: false, leftovers: false, queueManifest: reader, distinctRecords: true)
        defer { h.cleanup() }
        let before = try await h.beginHold(rebuildFails: reader)
        try h.syncHeld()
        try h.assertGuarded(before)
        XCTAssertTrue(h.skill.directoryName == "alpha"
            || h.library.error?.hasSuffix(SkillRenameTakeoverFixture.holdSentence) == true)
    }

}
