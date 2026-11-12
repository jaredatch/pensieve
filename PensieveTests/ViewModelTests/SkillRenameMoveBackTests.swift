import AppKit
import SwiftData
import SwiftUI
import WebKit
import XCTest
@testable import Pensieve

@MainActor
final class SkillRenameMoveBackTests: XCTestCase {
    func testARefusedRenameLeavesTheSkillUnderItsOldName() async throws {
        let h = try SkillRenameTakeoverFixture(record: false, leftovers: false)
        defer { h.cleanup() }
        let id = h.skill.id
        XCTAssertTrue(h.rename())
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { held.release() }
        let saved = h.library.editorBody(for: h.skill) + "\nSaved while waiting.\n"
        h.library.noteEditorChanged(h.skill, body: saved)
        XCTAssertTrue(h.library.saveDraft(h.skill))
        h.library.noteEditorChanged(h.skill, body: saved + "Typed while waiting.\n")
        h.library.unsavedChangesPresenter = { _, _ in }
        var allowedLeaving: Bool?
        h.library.confirmLeaving(h.skill) { allowedLeaving = $0 }
        try h.arrivePeer()
        let before = try ManifestSaveFixture.manifestBytes(root: h.root, files: h.files)
        held.release()
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.library.error, h.takenMessage())
        XCTAssertTrue(h.files.directoryExists(at: h.store.baseDir + "/alpha"))
        XCTAssertFalse(h.files.directoryExists(at: h.store.baseDir + "/zulu"))
        guard h.skill.directoryName == "alpha" else { return XCTFail("The skill never moved back") }
        let document = try h.files.readFile(at: h.store.baseDir + "/alpha/SKILL.md")
        XCTAssertEqual(SkillParser.parse(document).name, "Alpha")
        XCTAssertTrue(document.contains("Saved while waiting."))
        XCTAssertTrue(h.library.hasUnsavedChanges(for: h.skill))
        XCTAssertTrue(h.library.editorBody(for: h.skill).contains("Typed while waiting."))
        XCTAssertEqual(h.library.pendingUnsavedChanges?.directoryName, "alpha")
        h.library.resolveUnsavedChanges(.cancel)
        XCTAssertEqual(allowedLeaving, false)
        XCTAssertTrue(h.library.saveDraft(h.skill), h.library.error ?? "")
        XCTAssertTrue(try h.files.readFile(at: h.store.baseDir + "/alpha/SKILL.md").contains("Typed while waiting."))
        let row = try XCTUnwrap(h.context.fetch(FetchDescriptor<Skill>()).first { $0.id == id })
        XCTAssertTrue(row === h.skill)
        XCTAssertEqual(row.name, "Alpha")
        XCTAssertEqual(row.tags, ["own"])
        XCTAssertEqual(row.scope, .project)
        try assertWindowAssignmentsAndDeployments(h)
        XCTAssertEqual(try ManifestSaveFixture.manifestBytes(root: h.root, files: h.files), before)
        XCTAssertEqual(h.saves.pendingCount, 0)
    }

    func testChangesAfterARefusedRenameStayOnThisMacsSkill() async throws {
        let h = try SkillRenameTakeoverFixture(record: false, leftovers: false)
        defer { h.cleanup() }
        let categories = [Pensieve.Category(name: "Queued"), Pensieve.Category(name: "Later")]
        for category in categories { h.context.insert(category) }
        try h.context.save()
        try h.manifest.write(try h.manifest.snapshot(from: h.context), toRoot: h.root)
        XCTAssertTrue(h.rename())
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { held.release() }
        h.library.updateMetadata(h.skill, tags: ["queued"], scope: .project, context: h.context)
        h.library.updateMetadata(h.skill, tags: ["queued"], scope: .user, context: h.context)
        let store = CategoryStore(manifestSaves: h.saves)
        store.setSkill(h.skill, inCategory: categories[0], assigned: true, context: h.context)
        try h.arrivePeer()
        let peer = try h.files.readData(at: h.root + "/manifest/skills/zulu.yaml")
        held.release()
        await h.saves.waitUntilIdle()
        try assertEdits(h, peer: peer, tags: ["queued"], scope: .user, categories: ["Queued"])
        h.library.updateMetadata(h.skill, tags: ["later"], scope: .project, context: h.context)
        store.setSkill(h.skill, inCategory: categories[1], assigned: true, context: h.context)
        await h.saves.waitUntilIdle()
        try assertEdits(h, peer: peer, tags: ["later"], scope: .project, categories: ["Queued", "Later"])
        let snapshot = try StoreIngestState.snapshotForPublication(using: h.manifest, context: h.context, root: h.root)
        try h.manifest.write(snapshot, toRoot: h.root)
        let disk = try h.manifest.read(fromRoot: h.root)
        let own = try XCTUnwrap(disk.skills.first { $0.slug == "alpha" })
        XCTAssertTrue(ManifestService.sameCreation(own, h.own))
        XCTAssertEqual(own.tags, ["later"])
        XCTAssertEqual(own.scope, .project)
        XCTAssertFalse(disk.skills.contains { $0.slug == "zulu" && ManifestService.sameCreation($0, h.own) })
    }

    func testARenameTheLibraryCantAccountForIsRefusedAndKeepsThisMacsTagsAndScope() async throws {
        let h = try SkillRenameTakeoverFixture(record: false, leftovers: false)
        defer { h.cleanup() }
        let id = h.skill.id
        XCTAssertTrue(h.rename())
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { held.release() }
        try h.arrivePeer(removingOld: true)
        var pulled = try h.manifest.read(fromRoot: h.root)
        let otherIndex = try XCTUnwrap(pulled.skills.firstIndex { $0.slug == "other" })
        pulled.skills[otherIndex].tags = ["pulled"]
        pulled.skills[otherIndex].scope = .project
        pulled.categories.removeAll { $0.name == "Own" }
        pulled.categories.append(CategoryRecord(name: "Remote", projectKeys: [], skillSlugs: ["other"]))
        try h.manifest.write(pulled, toRoot: h.root)
        try h.moveHead()
        let peer = try h.files.readData(at: h.root + "/manifest/skills/zulu.yaml")
        held.release()
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.library.error, h.takenMessage())
        XCTAssertTrue(h.files.directoryExists(at: h.store.baseDir + "/alpha"))
        XCTAssertEqual(h.skill.directoryName, "alpha")
        XCTAssertEqual(h.skill.id, id)
        XCTAssertEqual(h.skill.tags, ["own"])
        XCTAssertEqual(h.skill.scope, .project)
        XCTAssertEqual(try h.files.readData(at: h.root + "/manifest/skills/zulu.yaml"), peer)
        XCTAssertEqual(h.other.tags, ["pulled"])
        XCTAssertEqual(h.other.scope, .project)
        // Use sync's rebuild admission and publication boundary. An unapplied HEAD must not
        // let this window overwrite pulled skills or resurrect a removed category.
        try StoreIngestState.rebuildIfNeeded(using: StoreRebuildService(fileService: h.files),
            root: h.root, context: h.context, files: h.files)
        let publication = try StoreIngestState.snapshotForPublication(using: h.manifest, context: h.context, root: h.root)
        try h.manifest.write(publication, toRoot: h.root)
        let afterSync = try h.manifest.read(fromRoot: h.root)
        XCTAssertEqual(afterSync.skills.first { $0.slug == "other" }?.tags, ["pulled"])
        XCTAssertEqual(afterSync.skills.first { $0.slug == "other" }?.scope, .project)
        XCTAssertEqual(afterSync.categories.first { $0.name == "Remote" }?.skillSlugs, ["other"])
        XCTAssertFalse(afterSync.categories.contains { $0.name == "Own" })
    }

    func testASkillWhoseRenameIsStillSavingCantBeRenamedOrDeleted() async throws {
        let h = try SkillRenameTakeoverFixture(record: false, leftovers: false)
        defer { h.cleanup() }
        XCTAssertTrue(h.rename())
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { held.release() }
        let queued = h.saves.pendingCount
        XCTAssertFalse(SkillRenameFlow.rename(skill: h.skill, to: "Again", library: h.library,
            platformVM: h.platform, projects: h.projects, context: h.context))
        XCTAssertEqual(h.library.error, "Pensieve is still saving this skill's rename. Try again in a moment.")
        XCTAssertEqual(h.skill.directoryName, "zulu")
        XCTAssertEqual(h.saves.pendingCount, queued)
        XCTAssertTrue(h.files.directoryExists(at: h.store.baseDir + "/zulu"))
        XCTAssertFalse(h.files.directoryExists(at: h.store.baseDir + "/again"))
        XCTAssertFalse(SkillDeletionFlow.delete(skill: h.skill, library: h.library, platformVM: h.platform,
            projects: h.projects, context: h.context))
        XCTAssertEqual(h.library.deletionNotice?.message,
            "Pensieve is still saving this skill. Try deleting it again in a moment.")
        XCTAssertEqual(h.skill.directoryName, "zulu")
        XCTAssertTrue(h.files.directoryExists(at: h.store.baseDir + "/zulu"))
        XCTAssertEqual(h.saves.pendingCount, queued)
        held.release()
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.saves.pendingCount, 0)
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root).skills.first { $0.slug == "zulu" }?.tags, ["own"])
    }

    func testAnOpenEditorFollowsTheDraftWhenARefusedRenameMovesBack() async throws {
        let h = try SkillRenameTakeoverFixture(record: false, leftovers: false)
        defer { h.cleanup() }
        let suffix = "\nTyped in the open editor.\n"
        let expected = h.library.editorBody(for: h.skill) + suffix
        XCTAssertTrue(h.rename())
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { held.release() }
        let typed = h.library.editorBody(for: h.skill) + suffix
        h.library.noteEditorChanged(h.skill, body: typed)
        let host = NSHostingView(rootView: SkillEditorView(skill: h.skill, library: h.library))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        let editor = try await TestWait.waitForEditor(in: host)
        let initial = await TestWait.waitForEditorText(typed, in: editor,
            timeout: .seconds(TestWait.hostedActionTimeoutSeconds))
        XCTAssertEqual(initial, typed)
        try h.arrivePeer()
        held.release()
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.library.error, h.takenMessage())
        let moved = await TestWait.waitForEditorText(expected, in: editor,
            timeout: .seconds(TestWait.hostedActionTimeoutSeconds))
        XCTAssertEqual(moved, expected, "The mounted editor must show the draft's restored name and typed text")
    }

    private func assertWindowAssignmentsAndDeployments(_ h: SkillRenameTakeoverFixture) throws {
        let disk = try h.manifest.read(fromRoot: h.root)
        let window = try h.manifest.snapshot(from: h.context)
        XCTAssertEqual(window.categories.sorted { $0.name < $1.name }, disk.categories.sorted { $0.name < $1.name })
        func intentKey(_ intent: DeployIntentRecord) -> String {
            [intent.machineID, intent.skillSlug, intent.platformRaw, intent.projectKey ?? ""].joined(separator: "|")
        }
        XCTAssertEqual(window.deployIntents.sorted { intentKey($0) < intentKey($1) },
            disk.deployIntents.sorted { intentKey($0) < intentKey($1) })
        XCTAssertEqual(try h.files.symlinkTarget(at: h.projects[0].path + "/.claude/skills/alpha"), h.store.baseDir + "/alpha")
        for project in h.projects {
            for suffix in ["/.claude/skills/zulu", "/.cursor/rules/zulu.mdc"] {
                XCTAssertFalse(try h.files.entryExistsWithoutFollowingLinks(at: project.path + suffix))
            }
        }
    }

    private func assertEdits(_ h: SkillRenameTakeoverFixture, peer: Data, tags: [String], scope: SkillScope,
                             categories: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try h.files.readData(at: h.root + "/manifest/skills/zulu.yaml"), peer, file: file, line: line)
        let disk = try h.manifest.read(fromRoot: h.root)
        XCTAssertEqual(disk.skills.first { $0.slug == "alpha" }?.tags, tags, file: file, line: line)
        XCTAssertEqual(disk.skills.first { $0.slug == "alpha" }?.scope, scope, file: file, line: line)
        for name in categories {
            XCTAssertEqual(disk.categories.first { $0.name == name }?.skillSlugs, ["alpha"], file: file, line: line)
        }
        XCTAssertEqual(h.saves.pendingCount, 0, file: file, line: line)
    }
}
