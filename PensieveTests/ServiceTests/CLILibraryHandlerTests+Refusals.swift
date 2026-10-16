import Foundation
import SwiftData
import XCTest
@testable import Pensieve

extension CLILibraryHandlerTests {
    func testBuiltUpdateRefusesWhileRealWindowApplyIsRunning() async throws {
        let remote = CLILibraryRemoteGate(owner: self)
        defer { remote.gate.open() }
        let h = try CLILibraryFixture(remoteGate: remote)
        defer { h.stop() }
        try await h.start()
        _ = try await h.run(["install", h.sourceURL, "--yes"])
        try h.files.writeFile(at: h.repository + "/skills/foo/SKILL.md", content: CLILibraryFixture.document("updated"))
        try await h.commit()
        _ = try await h.run(["skill", "outdated"])
        let model = h.runtime.updates
        await model.loadAndReport(context: h.context)
        XCTAssertEqual(model.rows.count, 1)
        remote.arm()
        model.applySelected(context: h.context)
        await TestWait.until(failureMessage: "Window update reaches the network boundary") { remote.gate.waiterCount == 1 }
        XCTAssertTrue(model.isApplying)
        let before = try h.tree(h.paths.storeRoot)
        let refused = try await h.run(["skill", "update", "foo", "--yes"], exit: 1)
        XCTAssertEqual(refused.error?.code, "update_in_progress")
        XCTAssertEqual(refused.error?.retryable, true)
        XCTAssertEqual(refused.changed, false)
        XCTAssertEqual(try h.tree(h.paths.storeRoot), before)
        remote.gate.open()
        await TestWait.until(failureMessage: "Real window update completes") { !model.isApplying }
        XCTAssertEqual(model.status(for: try XCTUnwrap(model.rows.first)), .updated)
        XCTAssertEqual(try h.files.readFile(at: h.paths.skillsDir + "/foo/SKILL.md"), CLILibraryFixture.document("updated"))
    }

    func testBuiltConfirmationPlansAndTerminalPolicy() async throws {
        let h = try CLILibraryFixture()
        defer { h.stop() }
        try await h.start()
        let before = try h.tree(h.paths.storeRoot)
        for (arguments, terminal, environment) in [
            (["install", h.sourceURL], false, [:]),
            (["install", h.sourceURL, "--no-input"], true, [:]),
            (["install", h.sourceURL], true, ["PENSIEVE_NO_INPUT": "1"])
        ] {
            let reply = try await h.run(arguments, exit: 5, terminal: terminal, environment: environment)
            XCTAssertEqual(reply.error?.code, "confirmation_required")
            XCTAssertNotNil(reply.data?["skills"])
            XCTAssertEqual(reply.next?.count, 1)
            XCTAssertTrue(reply.next?.first?.contains("--yes") == true)
            XCTAssertTrue(reply.next?.first?.contains("--app-support " + h.paths.appSupportDir) == true)
            XCTAssertEqual(try h.tree(h.paths.storeRoot), before)
        }
        try await assertChangedInstallConfirmation(h)
        let installed = try await h.run(["install", h.sourceURL], terminal: true)
        XCTAssertEqual(installed.changed, true)
        let folder = h.root + "/project with spaces"
        try h.files.createDirectory(at: folder)
        _ = try await h.run(["project", "add", folder])
        for command in [["skill", "update", "foo"], ["skill", "delete", "foo"], ["project", "remove", folder]] {
            let stable = try h.tree(h.root + "/home")
            let reply = try await h.run(command, exit: 5)
            XCTAssertEqual(reply.error?.code, "confirmation_required")
            XCTAssertNotNil(reply.data)
            XCTAssertEqual(try h.tree(h.root + "/home"), stable)
        }
        let removal = try await h.run(["project", "remove", folder], exit: 5)
        XCTAssertTrue(removal.next?.first?.contains("'" + folder + "'") == true)
        try await assertPromptFailureCleanup(h)
    }

    func testProjectCanonicalizationAndRegistrationLeaveTheMainActor() async throws {
        let h = try CLILibraryFixture()
        defer { h.stop() }
        try await h.start()
        let files = CLIProjectFileService()
        let folder = h.root + "/thread-project"
        try h.files.createDirectory(at: folder)
        let handler = CLILibraryHandler(runtime: h.runtime, files: files)
        let added = try await handler.addProject(folder, options: CLILibraryOptions(name: "~notes"))
        XCTAssertTrue(added.envelope.ok)
        let resolver = CLINameResolver(context: h.context, files: files)
        let project = try await resolver.project(folder, cwd: h.root)
        XCTAssertEqual(project.name, "~notes")
        let named = try await resolver.project("~notes", cwd: h.root)
        XCTAssertEqual(named.id, project.id)
        XCTAssertGreaterThan(files.probeCounts.total, 0, "The real filesystem boundary must be exercised")
        XCTAssertEqual(files.probeCounts.main, 0, "Project path work must not block the main actor")
    }

    func testBuiltProjectSaveFailureUsesRealReadOnlyStore() async throws {
        let h = try CLILibraryFixture(readOnly: true)
        defer { h.stop() }
        try await h.start()
        let folder = h.root + "/project"
        try h.files.createDirectory(at: folder)
        let reply = try await h.run(["project", "add", folder], exit: 1)
        XCTAssertFalse(reply.ok)
        XCTAssertTrue(reply.error?.message.localizedCaseInsensitiveContains("permission") == true, String(describing: reply))
        XCTAssertEqual(try ModelContext(h.context.container).fetchCount(FetchDescriptor<Project>()), 0, "Durable store")
        XCTAssertTrue(try h.context.fetch(FetchDescriptor<Project>()).isEmpty)
        let listed = try await h.run(["project", "list"])
        XCTAssertEqual(listed.data?.array, [])
        let repeated = try await h.run(["project", "add", folder], exit: 1)
        XCTAssertFalse(repeated.ok)
        let project = try ProjectRegistration.makeProject(name: "Window", path: folder)
        XCTAssertThrowsError(try registerProject(project, context: h.context))
        XCTAssertTrue(try h.context.fetch(FetchDescriptor<Project>()).isEmpty)
        XCTAssertEqual(try ModelContext(h.context.container).fetchCount(FetchDescriptor<Project>()), 0)
    }

    func testBuiltAddFencesReportWindowReason() async throws {
        let h = try CLILibraryFixture()
        defer { h.stop() }
        // Corrupt durable schema is ingested by the actual launch flow, not an injected fence answer.
        try h.files.createDirectory(at: h.paths.storeRoot + "/manifest")
        try h.files.writeFile(at: h.paths.storeRoot + "/manifest/manifest.yaml", content: "schema_version: 999\n")
        try await h.start()
        XCTAssertTrue(h.runtime.library.addsFenced)
        let reason = h.runtime.library.addFenceReason
        for command in [["install", h.sourceURL, "--yes"], ["project", "add", h.root]] {
            let reply = try await h.run(command, exit: 1)
            XCTAssertEqual(reply.error?.code, "store_unreadable")
            XCTAssertEqual(reply.error?.message, reason)
        }
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Skill>()), 0)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Project>()), 0)
    }

    func testBuiltDeletionAndProjectRemovalReportRealFilesystemPartialFailures() async throws {
        let h = try CLILibraryFixture()
        defer { h.stop() }
        try await h.start()
        _ = try await h.run(["install", h.sourceURL, "--yes"])
        _ = try await h.run(["deploy", "foo", "-a", "claude", "-g"])
        // Removing the owned link succeeds, then unlinking the skill directory fails on its parent permissions.
        let skillDirectory = h.paths.skillsDir + "/foo"
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: skillDirectory)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: skillDirectory) }
        let deleted = try await h.run(["skill", "delete", "foo", "--yes"], exit: 1)
        XCTAssertNil(h.runtime.library.deletionNotice, "CLI failure belongs in its reply, not the window alert")
        XCTAssertEqual(deleted.error?.code, "partial")
        XCTAssertEqual(deleted.changed, true)
        XCTAssertEqual(deleted.data?["skillRetained"], .bool(true))
        XCTAssertFalse(h.files.isSymlink(at: h.root + "/home/.claude/skills/foo"))
        XCTAssertNotNil(try h.skill())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: skillDirectory)
        _ = try await h.run(["skill", "delete", "foo", "--yes"])
        _ = try await h.run(["install", h.sourceURL, "--yes"])
        let folder = h.root + "/project"
        try h.files.createDirectory(at: folder)
        _ = try await h.run(["project", "add", folder, "--name", "Project"])
        _ = try await h.run(["deploy", "foo", "-a", "claude", "-p", folder])
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 1)
        let parent = folder + "/.claude/skills"
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent) }
        let removed = try await h.run(["project", "remove", "Project", "--yes"], exit: 1)
        XCTAssertEqual(removed.error?.code, "partial")
        XCTAssertEqual(removed.data?["withdrewRequests"], .bool(true), String(describing: removed))
        XCTAssertTrue(h.files.isSymlink(at: parent + "/foo"))
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Project>()), 1)
        try await assertQueuedDeleteFailure()
    }
}
