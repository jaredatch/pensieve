import SwiftData
import XCTest
@testable import Pensieve

extension StoreRebuildServiceTests {
    @MainActor
    func testNonScalarKeyFileIsSkippedWithWarning() throws {
        let context = try makeContext()
        let content = "---\nname: Hostile\ndescription: Hostile\nmeta:\n  ? [x]\n  : y\n---\nBody\n"
        try fileService.writeFile(
            at: tempDir + "/skills/hostile/SKILL.md",
            content: content
        )
        try writeManifest(skills: [])

        let result = service.rebuild(fromRoot: tempDir, context: context)

        XCTAssertEqual(result.skillsInserted, 0)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Skill>()).isEmpty)
        XCTAssertTrue(result.warnings.contains { $0.contains("hostile") })
    }
}
