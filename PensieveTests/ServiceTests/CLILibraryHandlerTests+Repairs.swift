import Foundation
import SwiftData
import XCTest
@testable import Pensieve

extension CLILibraryHandlerTests {
    func assertChangedInstallConfirmation(_ h: CLILibraryFixture) async throws {
        let shown = try await h.run(["install", h.sourceURL], exit: 5)
        try h.files.writeFile(at: h.repository + "/skills/foo/asset.txt", content: "changed after confirmation")
        try await h.commit()
        let before = try h.tree(h.paths.storeRoot)
        let refused = try await h.rerun(shown, exit: 5)
        XCTAssertEqual(refused.error?.code, "confirmation_required", "Changed install must ask again")
        XCTAssertEqual(try h.tree(h.paths.storeRoot), before, "Stale confirmation applies nothing")
        XCTAssertNotEqual(refused.data?["commit"], shown.data?["commit"])
        let terminal = try await h.run(["install", h.sourceURL], exit: 5, terminal: true, beforeConfirmation: {
            try h.files.writeFile(at: h.repository + "/skills/foo/asset.txt", content: "changed during terminal prompt")
            try await h.commit()
        })
        XCTAssertEqual(terminal.error?.code, "confirmation_required")
        XCTAssertEqual(try h.tree(h.paths.storeRoot), before, "Terminal confirmation applies only the shown commit")
    }

    func seedPendingRegistration(_ h: CLILibraryFixture, folder: String) throws {
        let identity = try ProjectRegistration.makeProject(name: "Pending", path: folder)
        let key = try XCTUnwrap(identity.identityKey)
        let machine = try XCTUnwrap(h.runtime.machineObservability.identity.existingIdentifier())
        h.context.insert(MachineDeployIntent(machineID: machine, skillSlug: "foo", platformRaw: "claudeCode", projectKey: key))
        try h.context.save()
    }

    func assertUpdateDeadline() async throws {
        let remote = CLILibraryRemoteGate(owner: self)
        let h = try CLILibraryFixture(remoteGate: remote)
        defer { h.stop() }
        try await h.start()
        _ = try await h.run(["install", h.sourceURL, "--yes"])
        try await h.assertNetworkDeadline(["skill", "update", "foo", "--yes"], remote: remote)
    }

    func assertDriftRefusalBeforeConfirmation(_ h: CLILibraryFixture) async throws {
        let before = try h.tree(h.paths.storeRoot)
        let preview = try await h.run(["skill", "update", "foo", "--dry-run"])
        XCTAssertEqual(preview.data?["skills"]?.array?.first?["action"], .string("update"))
        XCTAssertEqual(preview.data?["skills"]?.array?.first?["drifted"], .bool(true))
        for terminal in [false, true] {
            let refused = try await h.run(["skill", "update", "foo"], exit: 1,
                terminal: terminal, expectsPrompt: false)
            XCTAssertEqual(refused.error?.code, "local_changes", "Drift is refused before confirmation")
            XCTAssertTrue(refused.error?.hint.contains("--overwrite-local-changes") == true)
            XCTAssertNil(refused.next, "A refused update must not print a confirmation rerun")
            XCTAssertEqual(try h.tree(h.paths.storeRoot), before)
        }
    }

    func assertChangedUpdateConfirmation(_ h: CLILibraryFixture) async throws {
        let shown = try await h.run(["skill", "update", "foo", "--overwrite-local-changes"], exit: 5)
        try h.files.writeFile(at: h.repository + "/skills/foo/new.txt", content: "new upstream plan")
        try await h.commit()
        let before = try h.tree(h.paths.storeRoot)
        let refused = try await h.rerun(shown, exit: 5)
        XCTAssertEqual(refused.error?.code, "confirmation_required")
        XCTAssertEqual(try h.tree(h.paths.storeRoot), before, "Changed update plan writes nothing")
    }

    func assertChangedDeleteConfirmation(_ h: CLILibraryFixture) async throws {
        let shown = try await h.run(["skill", "delete", "foo"], exit: 5)
        let folder = h.root + "/later-project"
        try h.files.createDirectory(at: folder)
        _ = try await h.run(["project", "add", folder])
        _ = try await h.run(["deploy", "foo", "-a", "claude", "-p", folder])
        let before = try h.tree(h.root + "/home")
        let refused = try await h.rerun(shown, exit: 5)
        XCTAssertEqual(refused.error?.code, "confirmation_required")
        XCTAssertEqual(try h.tree(h.root + "/home"), before, "Changed deletion plan removes nothing")
        XCTAssertTrue(h.files.isSymlink(at: folder + "/.claude/skills/foo"))
    }

    func assertChangedRemovalConfirmation(_ h: CLILibraryFixture, folder: String) async throws {
        let shown = try await h.run(["project", "remove", "Work"], exit: 5)
        XCTAssertNotNil(h.runtime.library.createSkill(name: "Bar", description: "Second", body: "body",
            tags: [], context: h.context))
        await h.runtime.library.manifestSaves?.waitUntilIdle()
        _ = try await h.run(["undeploy", "foo", "-a", "claude", "-p", folder])
        _ = try await h.run(["deploy", "bar", "-a", "claude", "-p", folder])
        let before = try h.tree(folder)
        let refused = try await h.rerun(shown, exit: 5)
        XCTAssertEqual(refused.error?.code, "confirmation_required")
        XCTAssertEqual(refused.data?["artifactCount"], shown.data?["artifactCount"], "Same count, different artifact")
        XCTAssertEqual(try h.tree(folder), before, "Changed removal plan removes nothing")
    }

    func assertQueuedDeleteFailure() async throws {
        let h = try CLILibraryFixture()
        defer { h.stop() }
        try await h.start()
        _ = try await h.run(["install", h.sourceURL, "--yes"])
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: h.paths.storeRoot)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.paths.storeRoot) }
        let deleted = try await h.run(["skill", "delete", "foo", "--yes"], exit: 1)
        XCTAssertEqual(deleted.error?.code, "partial", "Queued manifest failure is returned to the CLI")
        XCTAssertNil(h.runtime.library.deletionNotice, "Queued deletion failure raises no window alert")
        XCTAssertNil(h.runtime.library.error, "CLI failure does not replace the window's error")
        XCTAssertFalse(h.files.directoryExists(at: h.paths.skillsDir + "/foo"))
    }

    func assertMixedDriftPlan(_ h: CLILibraryFixture) async throws {
        try h.files.createDirectory(at: h.repository + "/skills/bar")
        try h.files.writeFile(at: h.repository + "/skills/bar/SKILL.md", content: CLILibraryFixture.document("bar"))
        try await h.commit()
        _ = try await h.run(["install", h.sourceURL, "--skill", "bar", "--yes"])
        try h.files.writeFile(at: h.repository + "/skills/bar/SKILL.md", content: CLILibraryFixture.document("new bar"))
        try await h.commit()
        let preview = try await h.run(["skill", "update", "foo", "bar", "--dry-run"])
        let rows = try XCTUnwrap(preview.data?["skills"]?.array)
        XCTAssertEqual(rows.first { $0["slug"] == .string("foo") }?["action"], .string("unchanged"))
        XCTAssertEqual(rows.first { $0["slug"] == .string("foo") }?["drifted"], .bool(true))
        XCTAssertEqual(rows.first { $0["slug"] == .string("bar") }?["action"], .string("update"))
        let updated = try await h.run(["skill", "update", "foo", "bar", "--yes"])
        XCTAssertEqual(updated.changed, true)
        XCTAssertEqual(try h.files.readFile(at: h.paths.skillsDir + "/bar/SKILL.md"), CLILibraryFixture.document("new bar"))
        XCTAssertEqual(try h.files.readFile(at: h.paths.skillsDir + "/foo/asset.txt"), "unchanged upstream, local edit")
    }

    func assertUpdateRepairs(_ h: CLILibraryFixture) async throws {
        // This existing quarantine seam represents a failed SwiftData fetch; all command work is real.
        h.runtime.library.refreshQuarantine(context: h.context) { _ in throw CocoaError(.persistentStoreOperation) }
        let before = try h.tree(h.paths.storeRoot)
        let unavailable = try await h.run(["skill", "update", "foo", "--yes"], exit: 1)
        XCTAssertEqual(unavailable.error?.code, "store_unreadable", "Unavailable library refuses updates")
        XCTAssertEqual(unavailable.error?.message, h.runtime.library.persistentFenceReason)
        XCTAssertEqual(try h.tree(h.paths.storeRoot), before)
        h.runtime.library.refreshQuarantine(context: h.context)

        try h.files.writeFile(at: h.paths.skillsDir + "/foo/asset.txt", content: "unchanged upstream, local edit")
        let preview = try await h.run(["skill", "update", "foo", "--dry-run"])
        XCTAssertEqual(preview.data?["skills"]?.array?.first?["drifted"], .bool(true), "Dry run reports drift")
        let unchanged = try await h.run(["skill", "update", "foo", "--yes"])
        XCTAssertEqual(unchanged.changed, false, "No update does not overwrite or refuse local edits")
        try await assertMixedDriftPlan(h)

        try h.files.writeFile(at: h.repository + "/skills/foo/SKILL.md",
            content: CLILibraryFixture.document("partial update"))
        try await h.commit()
        h.runtime.library.stopWatching()
        let token = h.runtime.library.reloadToken
        let manifest = h.paths.storeRoot + "/manifest"
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: manifest)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: manifest) }
        let partial = try await h.run(["skill", "update", "foo", "--yes", "--overwrite-local-changes"], exit: 1)
        XCTAssertEqual(partial.error?.code, "partial")
        XCTAssertEqual(try h.files.readFile(at: h.paths.skillsDir + "/foo/SKILL.md"),
            CLILibraryFixture.document("partial update"))
        XCTAssertTrue(h.runtime.library.wasLastWrittenByApp(directoryName: "foo",
            currentBody: CLILibraryFixture.document("partial update")))
        XCTAssertGreaterThan(h.runtime.library.reloadToken, token,
            "A written body invalidates the editor even when publication fails")
    }
}

extension CLILibraryFixture {
    /// Execute precisely the command returned to the person, using the built tool on PATH.
    func rerun(_ reply: CLIEnvelope, exit: Int32) async throws -> CLIEnvelope {
        let command = try XCTUnwrap(reply.next?.first)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers").path + ":/usr/bin:/bin"
        environment["HOME"] = root + "/home"
        environment["CFFIXED_USER_HOME"] = root + "/home"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let result = try await BlockingWork.run { try CLIProcessProbe.run(process, timeout: 40) }
        let bytes = try output.fileHandleForReading.readToEnd() ?? Data()
        XCTAssertEqual(result.status, exit, String(data: bytes, encoding: .utf8) ?? "Invalid UTF-8")
        return try JSONDecoder().decode(CLIEnvelope.self, from: bytes)
    }
}
