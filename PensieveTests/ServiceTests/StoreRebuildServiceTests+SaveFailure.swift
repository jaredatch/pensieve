import SwiftData
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
            XCTAssertEqual(result.warnings.isEmpty, !saveFails)
            XCTAssertTrue(context.hasChanges)
            XCTAssertEqual(result.skillsInserted, 1)
            let saved = ModelContext(context.container)
            XCTAssertEqual(try saved.fetch(FetchDescriptor<Project>()).first?.name, "Saved name")
            XCTAssertEqual(try saved.fetchCount(FetchDescriptor<Skill>()), saveFails ? 0 : 1)
        }
    }
}
