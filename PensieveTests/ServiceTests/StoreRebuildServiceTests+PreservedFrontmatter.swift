import SwiftData
import XCTest
@testable import Pensieve

extension StoreRebuildServiceTests {
    @MainActor
    func testRejectedFenceShapesKeepLibraryRowsAndWarnAcrossLFAndCRLF() throws {
        for ending in ["\n", "\r\n"] {
            for source in ["\n---\nname: New\ndescription: New\n---\nBody",
                           "---\nname: New\ndescription: New\n  ---\nBody"] {
                let context = try makeContext()
                let existing = Skill(name: "Existing", skillDescription: "Existing D", directoryName: "fence")
                context.insert(existing)
                try context.save()
                try writeManifest()
                let bytes = source.replacingOccurrences(of: "\n", with: ending)
                try fileService.writeFile(at: tempDir + "/skills/fence/SKILL.md", content: bytes)
                let result = service.rebuild(fromRoot: tempDir, context: context)
                XCTAssertEqual(result.skillsRemoved, 0)
                XCTAssertEqual(result.skillsUpdated, 0)
                XCTAssertEqual(try context.fetch(FetchDescriptor<Skill>()).map(\.name), ["Existing"])
                XCTAssertTrue(result.warnings.contains { $0.contains("'fence'") && $0.contains("missing required frontmatter") })
                XCTAssertEqual(try fileService.readData(at: tempDir + "/skills/fence/SKILL.md"), Data(bytes.utf8))
            }
        }
    }

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
