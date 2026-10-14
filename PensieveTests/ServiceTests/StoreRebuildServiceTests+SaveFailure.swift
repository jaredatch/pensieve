import SwiftData
import SQLite3
import XCTest
@testable import Pensieve

extension StoreRebuildServiceTests {
    @MainActor
    func testSaveFailureReportingIsIndependentOfPendingCallerEdits() throws {
        try writeSkillFile(slug: "skill", name: "Skill", description: "Description")
        for saveFails in [false, true] {
            let context = try makeContext()
            context.autosaveEnabled = false
            let project = Project(name: "Saved name", path: tempDir + "/project")
            context.insert(project)
            try context.save()
            let rebuild = StoreRebuildService(fileService: fileService, manifestService: manifest, save: { context in
                if saveFails { throw CocoaError(.fileWriteUnknown) }
                try context.save()
                project.name = "Pending local rename"
            })

            let result = rebuild.rebuild(fromRoot: tempDir, context: context)

            XCTAssertEqual(result.saveFailed, saveFails)
            XCTAssertEqual(result.ingestIncomplete, saveFails)
            XCTAssertEqual(result.warnings.isEmpty, !saveFails)
            XCTAssertTrue(context.hasChanges)
            XCTAssertEqual(result.skillsInserted, 1)
            let saved = ModelContext(context.container)
            XCTAssertEqual(try saved.fetch(FetchDescriptor<Project>()).first?.name, "Saved name")
            XCTAssertEqual(try saved.fetchCount(FetchDescriptor<Skill>()), saveFails ? 0 : 1)
        }
    }
}

extension StoreRebuildServiceTests {
    @MainActor
    func testFailedCategoryFetchIsDistinctFromNonAuthoritativeManifest() throws {
        let store = URL(fileURLWithPath: tempDir + "/library.store")
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(url: store))
        try NativeTestWork.run { [self] in
            let seed = ModelContext(container)
            seed.insert(Pensieve.Category(name: "Local"))
            try seed.save()
            // Break the actual SQLite fetch, independently of SwiftData's process-wide schema cache.
            try renameCategoryTable(at: store.path, broken: true)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let rebuild = StoreRebuildService(fileService: fileService, manifestService: manifest)
            let empty = ManifestSnapshot(schemaVersion: ManifestService.currentSchemaVersion,
                                         categories: [], projects: [], skills: [])
            let nonAuthoritative = rebuild.rebuild(snapshot: empty, fromRoot: tempDir, context: context,
                                                   manifestIsAuthoritative: false)
            XCTAssertNil(nonAuthoritative.categoryRead)
            XCTAssertFalse(nonAuthoritative.categoryReadFailed)
            XCTAssertFalse(nonAuthoritative.ingestIncomplete)
            let failed = rebuild.rebuild(snapshot: empty, fromRoot: tempDir, context: context,
                                         manifestIsAuthoritative: true)
            XCTAssertTrue(failed.warnings.contains { $0.contains("Couldn't read local categories") })
            XCTAssertNil(failed.categoryRead)
            XCTAssertTrue(failed.categoryReadFailed)
            XCTAssertTrue(failed.ingestIncomplete)
            XCTAssertFalse(failed.storeUnreadable)
            XCTAssertFalse(failed.saveFailed)
            try renameCategoryTable(at: store.path, broken: false)
            let recovered = rebuild.rebuild(snapshot: empty, fromRoot: tempDir, context: context,
                                            manifestIsAuthoritative: true)
            XCTAssertNotNil(recovered.categoryRead)
            XCTAssertFalse(recovered.categoryReadFailed)
            XCTAssertFalse(recovered.ingestIncomplete)
            XCTAssertEqual(recovered.categoriesRemoved, 1)
        }
    }

    /// Rename only this temporary store's Category table; the inverse restores its original rows.
    private func renameCategoryTable(at path: String, broken: Bool) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let opened = try XCTUnwrap(database)
        defer { sqlite3_close(opened) }
        let sql = broken ? "ALTER TABLE ZCATEGORY RENAME TO ZCATEGORY_BROKEN;"
            : "ALTER TABLE ZCATEGORY_BROKEN RENAME TO ZCATEGORY;"
        XCTAssertEqual(sqlite3_exec(opened, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(opened)))
    }
}
