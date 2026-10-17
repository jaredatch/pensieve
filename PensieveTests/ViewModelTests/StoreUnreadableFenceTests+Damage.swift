import XCTest
@testable import Pensieve

extension StoreUnreadableFenceTests {
    func testDamagedLaunchKeepsCategoriesEditableAndLocalRepairLiftsOnlyTheDamageFence() async throws {
        let h = try CLILibraryFixture()
        defer { h.stop() }
        try h.files.createDirectory(at: h.paths.storeRoot + "/manifest")
        try h.files.writeFile(at: h.paths.storeRoot + "/manifest/manifest.yaml", content: "damaged")
        try await h.start()
        let library = h.runtime.library
        let saves = try XCTUnwrap(library.manifestSaves)
        await saves.refreshAndRetry()
        XCTAssertFalse(library.categoryEditsFenced, "Launch damage leaves category edits available")
        XCTAssertTrue(library.addsFenced)
        XCTAssertEqual(library.addFenceReason,
            "Pensieve can't add to this library until the damaged library file is repaired.")
        XCTAssertNil(library.createSkill(name: "Blocked", description: "", body: "body", tags: [], context: h.context))
        XCTAssertEqual(library.error, library.addFenceReason)
        saves.requestRepair()
        await saves.replaceWithThisMac(context: h.context)
        XCTAssertNil(saves.repairError)
        XCTAssertFalse(library.addsFenced, "Local Replace clears damage without a remote or relaunch")
        XCTAssertFalse(library.categoryEditsFenced)
        XCTAssertNil(library.addFenceReason)
        try await assertNewerThenDamagedReadDoesNotLeaveAnOldFence(h)
    }

    private func assertNewerThenDamagedReadDoesNotLeaveAnOldFence(_ h: CLILibraryFixture) async throws {
        let library = h.runtime.library, saves = try XCTUnwrap(h.runtime.library.manifestSaves)
        try h.files.writeFile(at: h.paths.storeRoot + "/manifest/manifest.yaml", content: "schema_version: 999\n")
        await h.runtime.applyLibrarySyncOutcome(.storeUnreadable(
            ManifestError.unsupportedSchema(found: 999, supported: 5).localizedDescription))
        XCTAssertTrue(library.categoryEditsFenced)
        XCTAssertEqual(library.addFenceReason, SkillLibraryViewModel.storeUnreadableMessage)
        try h.files.writeFile(at: h.paths.storeRoot + "/manifest/manifest.yaml", content: "damaged again")
        await saves.refreshAndRetry()
        XCTAssertFalse(library.categoryEditsFenced, "Observed damage replaces an older newer-schema fence")
        XCTAssertEqual(library.addFenceReason,
            "Pensieve can't add to this library until the damaged library file is repaired.")
        saves.requestRepair()
        await saves.replaceWithThisMac(context: h.context)
        XCTAssertFalse(library.addsFenced, "Repair must not revive an older fence")
    }
}
