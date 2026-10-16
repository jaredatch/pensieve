import SwiftData
import XCTest
@testable import Pensieve

extension CLILibraryHandlerTests {
    func testBuiltDeleteReportsDamagedManifestOnceAndRepairClearsWindowFailure() async throws {
        let h = try CLILibraryFixture()
        defer { h.stop() }
        try await h.start()
        _ = try await h.run(["install", h.sourceURL, "--yes"])
        try h.files.writeFile(at: h.paths.storeRoot + "/manifest/manifest.yaml", content: "damaged")
        let deleted = try await h.run(["skill", "delete", "foo", "--yes"], exit: 1)
        XCTAssertEqual(deleted.error?.code, "partial")
        XCTAssertEqual(deleted.changed, true)
        XCTAssertEqual(deleted.error?.hint, "Repair the library file in Pensieve.")
        let message = try XCTUnwrap(deleted.error?.message)
        XCTAssertTrue(message.contains("The library file is damaged. This change waits for its repair."), message)
        XCTAssertEqual(message.components(separatedBy: "damaged").count, 2)
        XCTAssertNil(h.runtime.library.deletionNotice)
        let saves = try XCTUnwrap(h.runtime.library.manifestSaves)
        saves.requestRepair()
        await saves.replaceWithThisMac(context: h.context)
        await saves.waitUntilIdle()
        XCTAssertNil(h.runtime.library.error)
        XCTAssertNil(h.runtime.library.deletionNotice)
        XCTAssertTrue(try h.context.fetch(FetchDescriptor<Skill>()).isEmpty)
    }
    func testBuiltLocalProjectDeployProceedsWhileAnotherProcessHoldsSyncLock() async throws {
        let h = try CLILibraryFixture()
        defer { h.stop() }
        try await h.start()
        _ = try await h.run(["install", h.sourceURL, "--yes"])
        let folder = h.root + "/local-project"
        try h.files.createDirectory(at: folder)
        let project = Project(name: "Local", path: folder)
        h.context.insert(project)
        try h.context.save()
        XCTAssertNil(project.identityKey)
        let held = try ExternalSyncLockHolder(path: h.paths.syncLockPath)
        defer { held.release() }
        let reply = try await h.run(["deploy", "foo", "-a", "claude", "-p", folder])
        XCTAssertTrue(reply.ok, "Local CLI deploy must not take sync.lock")
        XCTAssertTrue(h.files.isSymlink(at: folder + "/.claude/skills/foo"))
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
    }

}
