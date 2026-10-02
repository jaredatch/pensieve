import SwiftData
import XCTest
@testable import Pensieve

extension StoreRebuildServiceTests {
    @MainActor
    func testPreservedFrontmatterSkillIsAdmittedWithExistingFields() throws {
        let context = try makeContext()
        let content = """
        ---
        name: Preserved
        description: Preserved description
        license: Apache-2.0
        allowed-tools:
          - Read
        metadata:
          owner: upstream
        tags: [frontmatter-tag]
        scope: project
        ---

        Body
        """
        try fileService.writeFile(at: tempDir + "/skills/preserved/SKILL.md", content: content)
        try writeManifest(skills: [overlay("preserved", scope: .project, tags: ["frontmatter-tag"])])

        let result = service.rebuild(fromRoot: tempDir, context: context)

        XCTAssertEqual(result.skillsInserted, 1)
        let skill = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
        XCTAssertEqual(skill.name, "Preserved")
        XCTAssertEqual(skill.skillDescription, "Preserved description")
        XCTAssertEqual(skill.tags, ["frontmatter-tag"])
        XCTAssertEqual(skill.scope, .project)
    }
}
