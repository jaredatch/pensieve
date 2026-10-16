import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class CLILibraryHandlerTests: XCTestCase {
    func testBuiltInstallPreviewSelectionPinsAndURLAdmission() async throws {
        let remote = CLILibraryRemoteGate(owner: self)
        let h = try CLILibraryFixture(remoteGate: remote)
        defer { h.stop() }
        try await h.start()
        try h.files.createDirectory(at: h.repository + "/skills/bar")
        try h.files.writeFile(at: h.repository + "/skills/bar/SKILL.md", content: CLILibraryFixture.document("bar"))
        try await h.commit()
        let before = try h.tree(h.paths.storeRoot)
        let unknown = try await h.run(["install", h.sourceURL, "--skill", "unknown", "--dry-run"], exit: 1)
        XCTAssertEqual(unknown.error?.message, "A selected skill was not found. Preview the repository without --skill.")
        XCTAssertNil(unknown.data, "An unknown selection does not enumerate candidate slugs")
        let catalog = try await h.run(["install", h.sourceURL, "--dry-run"])
        XCTAssertEqual(catalog.data?["skills"]?.array?.map { $0["slug"] }, [.string("bar"), .string("foo")])
        let preview = try await h.run(["install", h.sourceURL, "--skill", "foo", "--dry-run"])
        XCTAssertEqual(preview.data?["skills"]?.array?.count, 1)
        XCTAssertEqual(preview.data?["skills"]?.array?.first?["slug"], .string("foo"))
        XCTAssertEqual(try h.tree(h.paths.storeRoot), before)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Skill>()), 0)
        XCTAssertEqual(try h.files.listDirectory(at: h.root + "/install-scratch"), [])
        let installed = try await h.run(["install", h.sourceURL, "--skill", "foo", "--yes"])
        XCTAssertEqual(installed.changed, true)
        let skill = try h.skill()
        let expected = try await BlockingWork.run { try h.git.commitSHA(at: h.repository) }
        XCTAssertEqual(skill.installedOrigin?.installedCommit, expected)
        XCTAssertEqual(skill.installedOrigin?.path, "skills/foo")
        XCTAssertEqual(try h.files.readFile(at: h.paths.skillsDir + "/foo/asset.txt"), "original asset")
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Skill>()), 1)
        let manifest = try await BlockingWork.run { try ManifestService().read(fromRoot: h.paths.storeRoot) }
        XCTAssertEqual(manifest.skills.first?.slug, "foo")
        let stable = try h.tree(h.paths.storeRoot)
        let rejected = try await h.run(["install", "https://example.invalid/fixture/skills", "--yes"], exit: 1)
        XCTAssertFalse(rejected.ok)
        XCTAssertEqual(try h.tree(h.paths.storeRoot), stable)
        try await h.assertNetworkDeadline(["install", h.sourceURL, "--skill", "foo", "--yes"], remote: remote)
    }

    func testBuiltInstallCollisionRenameSkipAndRepeat() async throws {
        let h = try CLILibraryFixture()
        defer { h.stop() }
        try await h.start()
        for name in ["Foo", "Foo 2"] {
            XCTAssertNotNil(h.runtime.library.createSkill(name: name, description: "Owned",
                body: "owned", tags: [], context: h.context))
        }
        await h.runtime.library.manifestSaves?.waitUntilIdle()
        let before = try h.tree(h.paths.storeRoot)
        let preview = try await h.run(["install", h.sourceURL, "--dry-run"])
        XCTAssertEqual(preview.data?["skills"]?.array?.first?["action"], .string("collision"))
        let refused = try await h.run(["install", h.sourceURL, "--yes"], exit: 5)
        XCTAssertEqual(refused.error?.code, "slug_collision")
        let skipped = try await h.run(["install", h.sourceURL, "--skip", "--yes"])
        XCTAssertEqual(skipped.changed, false)
        XCTAssertEqual(try h.tree(h.paths.storeRoot), before)
        let renamed = try await h.run(["install", h.sourceURL, "--rename", "--yes"])
        XCTAssertEqual(renamed.data?["skills"]?.array?.first?["slug"], .string("foo-3"))
        XCTAssertEqual(try h.skill("foo-3").installedOrigin?.path, "skills/foo")
        let installed = try h.tree(h.paths.storeRoot)
        let repeated = try await h.run(["install", h.sourceURL, "--yes"])
        XCTAssertEqual(repeated.changed, false)
        XCTAssertEqual(try h.tree(h.paths.storeRoot), installed)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Skill>()), 3)
    }

    func testBuiltOutdatedVerifiedUpdateDriftAndRepeat() async throws {
        let remote = CLILibraryRemoteGate(owner: self)
        let h = try CLILibraryFixture(remoteGate: remote)
        defer { h.stop() }
        try await h.start()
        _ = try await h.run(["install", h.sourceURL, "--yes"])
        try h.files.writeFile(at: h.repository + "/skills/foo/SKILL.md", content: CLILibraryFixture.document("upstream"))
        try h.files.writeFile(at: h.repository + "/skills/foo/asset.txt", content: "upstream asset")
        try await h.commit()
        remote.arm()
        h.runtime.checkForSkillUpdatesNow()
        await TestWait.until(failureMessage: "Window check reaches the real remote boundary") { remote.gate.waiterCount == 1 }
        let checks = remote.callCount
        async let checking = h.run(["skill", "outdated"])
        await TestWait.until(failureMessage: "CLI outdated waits for the window's check") { h.paths.syncSteps.pendingCount == 1 }
        remote.gate.open()
        let outdated = try await checking
        XCTAssertEqual(remote.callCount, checks, "CLI outdated joins the window's check instead of starting another")
        XCTAssertEqual(outdated.data?["skills"]?.array?.first?["slug"], .string("foo"))
        let head = try await BlockingWork.run { try h.git.commitSHA(at: h.repository) }
        XCTAssertEqual(outdated.data?["skills"]?.array?.first?["commit"], .string(head))
        let before = try h.tree(h.paths.storeRoot)
        let networkCalls = remote.callCount
        let preview = try await h.run(["skill", "update", "foo", "--dry-run"])
        XCTAssertEqual(remote.callCount - networkCalls, 1, "Update planning reuses its first checkout for verification")
        XCTAssertEqual(preview.data?["skills"]?.array?.first?["action"], .string("update"))
        XCTAssertEqual(try h.tree(h.paths.storeRoot), before)
        try h.files.writeFile(at: h.paths.skillsDir + "/foo/asset.txt", content: "local edit")
        let refused = try await h.run(["skill", "update", "foo", "--yes"], exit: 1)
        XCTAssertEqual(refused.error?.code, "local_changes")
        XCTAssertEqual(try h.files.readFile(at: h.paths.skillsDir + "/foo/asset.txt"), "local edit")
        remote.arm()
        async let planning = h.run(["skill", "update", "foo", "--yes"], exit: 5)
        await TestWait.until(failureMessage: "Update planning reaches the remote boundary") { remote.gate.waiterCount == 1 }
        let skill = try XCTUnwrap(h.context.fetch(FetchDescriptor<Skill>()).first { $0.directoryName == "foo" })
        h.runtime.library.noteEditorChanged(skill, body: "draft during planning")
        remote.gate.open()
        let draftRefusal = try await planning
        XCTAssertEqual(draftRefusal.error?.code, "unsaved_draft", "A new draft takes precedence over local drift")
        h.runtime.library.discardDraft(skill)
        try await assertDriftRefusalBeforeConfirmation(h)
        try await assertChangedUpdateConfirmation(h)
        let updated = try await h.run(["skill", "update", "foo", "--overwrite-local-changes", "--yes"])
        XCTAssertEqual(updated.changed, true)
        XCTAssertEqual(try h.files.readFile(at: h.paths.skillsDir + "/foo/asset.txt"), "upstream asset")
        XCTAssertEqual(try h.files.readFile(at: h.paths.skillsDir + "/foo/SKILL.md"), CLILibraryFixture.document("upstream"))
        let repeated = try await h.run(["skill", "update", "foo", "--yes"])
        XCTAssertEqual(repeated.changed, false)
        try await assertUpdateRepairs(h)
        try await h.assertNetworkDeadline(["skill", "outdated"], remote: remote)
        try await assertUpdateDeadline()
    }

    func testBuiltUpdateAndDeleteRefuseUnsavedWindowDraft() async throws {
        let h = try CLILibraryFixture()
        defer { h.stop() }
        try await h.start()
        _ = try await h.run(["install", h.sourceURL, "--yes"])
        let skill = try h.skill()
        let body = h.runtime.library.editorBody(for: skill)
        h.runtime.library.noteEditorChanged(skill, body: body + "unsaved")
        let before = try h.tree(h.paths.storeRoot)
        for arguments in [["skill", "update", "foo"], ["skill", "update", "foo", "--yes"],
                          ["skill", "update", "foo", "--overwrite-local-changes"],
                          ["skill", "update", "foo", "--yes", "--overwrite-local-changes"],
                          ["skill", "delete", "foo"], ["skill", "delete", "foo", "--yes"]] {
            let refused = try await h.run(arguments, exit: 5)
            XCTAssertEqual(refused.error?.code, "unsaved_draft")
        }
        XCTAssertEqual(try h.tree(h.paths.storeRoot), before)
        XCTAssertTrue(h.runtime.library.hasUnsavedChanges(for: skill))
    }

    func testBuiltDeletePreviewRemovesDeploysAndWaitsForManifest() async throws {
        let h = try CLILibraryFixture(diskBacked: true)
        defer { h.stop() }
        try await h.start()
        _ = try await h.run(["install", h.sourceURL, "--yes"])
        _ = try await h.run(["deploy", "foo", "-a", "claude", "-g"])
        let link = h.root + "/home/.claude/skills/foo"
        XCTAssertTrue(h.files.isSymlink(at: link))
        let assigned = Category(name: "Assigned"), unrelated = Category(name: "Unrelated")
        assigned.skillSlugs = ["foo"]
        unrelated.skillSlugs = ["other"]
        h.context.insert(assigned)
        h.context.insert(unrelated)
        try h.context.save()
        let before = try h.tree(h.root + "/home")
        let preview = try await h.run(["skill", "delete", "foo", "--dry-run"])
        XCTAssertEqual(preview.data?["categories"]?.array, [.string(assigned.id.uuidString)])
        XCTAssertEqual(preview.data?["deployments"]?.array?.first?["path"], .string(link))
        XCTAssertEqual(try h.tree(h.root + "/home"), before)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Skill>()), 1)
        try await assertChangedDeleteConfirmation(h)
        let historyID = try h.skill().id
        h.runtime.upstreamHistory.invalidateForManualCheck(skillID: historyID)
        XCTAssertEqual(h.runtime.upstreamHistory.manualCheckCount(skillID: historyID), 1)
        try await seedStaleManifestError(h)
        let deleted = try await h.run(["skill", "delete", "foo", "--yes"])
        XCTAssertNil(h.runtime.library.error, "A successful CLI manifest save clears the stale window error")
        XCTAssertEqual(h.runtime.upstreamHistory.manualCheckCount(skillID: historyID), 0, "CLI deletion retires history")
        XCTAssertEqual(deleted.changed, true)
        XCTAssertFalse(h.files.isSymlink(at: link))
        XCTAssertFalse(h.files.directoryExists(at: h.paths.skillsDir + "/foo"))
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Skill>()), 0)
        XCTAssertEqual(h.runtime.library.manifestSaves?.pendingCount, 0)
        let manifest = try await BlockingWork.run { try ManifestService().read(fromRoot: h.paths.storeRoot) }
        XCTAssertTrue(manifest.skills.isEmpty)
        XCTAssertTrue(manifest.deployIntents.isEmpty)
        let missing = try await h.run(["skill", "delete", "foo", "--yes"], exit: 4)
        XCTAssertEqual(missing.error?.code, "skill_not_found")
    }

    func testBuiltProjectPreviewRegistrationRepeatAndRemoval() async throws {
        let h = try CLILibraryFixture()
        defer { h.stop() }
        try await h.start()
        let folder = h.root + "/project with spaces"
        try h.files.createDirectory(at: folder)
        let preview = try await h.run(["project", "add", folder, "--name", "Work", "--dry-run"])
        XCTAssertEqual(preview.data?["name"], .string("Work"))
        XCTAssertFalse(h.files.fileExists(at: folder + "/.pensieve-project"))
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Project>()), 0)
        _ = try await h.run(["install", h.sourceURL, "--yes"])
        try seedPendingRegistration(h, folder: folder)
        let added = try await h.run(["project", "add", folder, "--name", "Work"])
        XCTAssertTrue(h.files.isSymlink(at: folder + "/.claude/skills/foo"), "Registration realizes pending intent immediately")
        XCTAssertEqual(added.changed, true)
        XCTAssertTrue(h.files.fileExists(at: folder + "/.pensieve-project"))
        let visible = try h.context.fetch(FetchDescriptor<Project>())
        XCTAssertEqual(visible.map(\.path), [folder])
        let listed = try await h.run(["project", "list"])
        XCTAssertEqual(listed.data?.array?.first?["id"], added.data?["id"])
        XCTAssertEqual(listed.data?.array?.first?["path"], .string(folder))
        let repeated = try await h.run(["project", "add", folder, "--name", "Other"])
        XCTAssertEqual(repeated.changed, false)
        XCTAssertEqual(repeated.data?["id"], added.data?["id"])
        _ = try await h.run(["install", h.sourceURL, "--yes"])
        _ = try await h.run(["deploy", "foo", "-a", "claude", "-p", folder])
        let link = folder + "/.claude/skills/foo"
        XCTAssertTrue(h.files.isSymlink(at: link))
        let before = try h.tree(folder)
        let removal = try await h.run(["project", "remove", "Work", "--dry-run"])
        XCTAssertEqual(removal.data?["artifactCount"], .number(1))
        XCTAssertEqual(try h.tree(folder), before)
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.paths.syncLockPath))
        defer { lock.release() }
        let busy = try await h.run(["project", "remove", "Work", "--yes"], exit: 1)
        XCTAssertEqual(busy.error?.code, "sync_running")
        XCTAssertEqual(busy.error?.retryable, true)
        XCTAssertEqual(busy.changed, false)
        XCTAssertEqual(try h.tree(folder), before)
        lock.release()
        try await assertChangedRemovalConfirmation(h, folder: folder)
        let removed = try await h.run(["project", "remove", "Work", "--yes"])
        XCTAssertEqual(removed.changed, true)
        XCTAssertFalse(h.files.isSymlink(at: link))
        XCTAssertTrue(h.files.directoryExists(at: folder))
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Project>()), 0)
        let missing = try await h.run(["project", "remove", "Work", "--yes"], exit: 4)
        XCTAssertEqual(missing.error?.code, "project_not_found")
    }
}

extension CLIValue {
    subscript(_ key: String) -> CLIValue? { if case .object(let fields) = self { return fields[key] }; return nil }
    var array: [CLIValue]? { if case .array(let items) = self { return items }; return nil }
}
