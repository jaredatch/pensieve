import Darwin
import SwiftData
import XCTest
@testable import Pensieve

extension ManifestSaveTests {
    func testUnreadableAndSpecialManifestEntriesCanBeRepairedButChangedEntriesCannot() async throws {
        for kind in ["unreadable", "fifo"] {
            let h = try ManifestSaveFixture()
            defer { h.cleanup() }
            let path = h.root + "/manifest/skills/alpha.yaml"
            if kind == "fifo" {
                try h.files.deleteFile(at: path)
                XCTAssertEqual(mkfifo(path, 0o600), 0)
            } else { XCTAssertEqual(chmod(path, 0), 0) }
            defer { _ = chmod(path, 0o600) }
            h.categories.rename(h.local, to: "Waiting", context: h.context)
            await h.saves.waitUntilIdle()
            XCTAssertTrue(h.saves.libraryDamaged)
            h.saves.requestRepair()
            // The same unreadable bytes/type with a new inode is still a changed offer.
            try h.files.moveDamageFixtureEntry(at: path, kind: kind)
            await h.saves.replaceWithThisMac(context: h.context)
            XCTAssertTrue(h.saves.libraryDamaged)
            XCTAssertEqual(h.saves.repairError, "The library file changed. Review the repair again.")
            XCTAssertTrue(h.saves.showsDamageAlert)
            h.saves.requestRepair()
            await h.saves.replaceWithThisMac(context: h.context)
            await h.saves.waitUntilIdle()
            XCTAssertNil(h.saves.repairError, "Confirmed \(kind) damage must be repairable")
            XCTAssertEqual(h.saves.pendingCount, 0)
            XCTAssertEqual(try h.manifest.read(fromRoot: h.root).categories.map(\.name), ["Waiting", "ZDelete"])
        }
    }

    func testPausedDeletionShowsOnlyDamageAndReportsSuccessAfterRepair() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "damaged")
        let presentation = SkillLibraryViewModel.DeletionPresentation()
        _ = h.library.deleteSkillEntry(h.alpha, context: h.context, presentation: presentation)
        await h.saves.waitUntilIdle()
        XCTAssertTrue(h.saves.showsDamageAlert)
        XCTAssertNil(h.library.deletionNotice, "The damage alert is the only pause notice")
        h.categories.rename(h.local, to: "Waiting", context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertNil(h.library.deletionNotice, "A second pause must not append another deletion failure")
        h.saves.requestRepair()
        await h.saves.replaceWithThisMac(context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertNil(presentation.notice, "A repaired deletion has no stale failure")
        XCTAssertNil(h.library.deletionNotice)
        XCTAssertFalse(try h.manifest.read(fromRoot: h.root).skills.contains { $0.slug == "alpha" })
    }
}

private extension FileService {
    func moveDamageFixtureEntry(at path: String, kind: String) throws {
        // Keep the original inode alive so the replacement cannot reuse it.
        XCTAssertEqual(rename(path, path + ".old"), 0)
        if kind == "fifo" { XCTAssertEqual(mkfifo(path, 0o600), 0) } else {
            XCTAssertEqual(chmod(path + ".old", 0o600), 0)
            try writeData(at: path, data: readData(at: path + ".old"))
            XCTAssertEqual(chmod(path, 0), 0)
        }
        try deleteFile(at: path + ".old")
    }
}
