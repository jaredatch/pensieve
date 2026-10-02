import SwiftData
import XCTest
@testable import Pensieve

extension StoreRebuildServiceTests {
    @MainActor
    func testRebuildSkipsSymlinkedSlugDirPreservingRowWithoutReadingThrough() throws {
        let context = try makeContext()
        // First rebuild ingests a real "victim" skill row.
        try writeSkillFile(slug: "victim", name: "Original", description: "orig")
        try writeManifest(skills: [overlay("victim")])
        _ = service.rebuild(fromRoot: tempDir, context: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Skill>()).count, 1)

        // Replace the real slug dir with a symlink to an out-of-store dir holding a DIFFERENT SKILL.md.
        try FileManager.default.removeItem(atPath: tempDir + "/skills/victim")
        let outside = tempDir + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        let evil = SkillSerializer.serialize(name: "Evil", description: "pwned", body: "# evil")
        try fileService.writeFile(at: outside + "/SKILL.md", content: evil)
        try FileManager.default.createSymbolicLink(atPath: tempDir + "/skills/victim", withDestinationPath: outside)

        let result = service.rebuild(fromRoot: tempDir, context: context)

        XCTAssertTrue(result.warnings.contains { $0.contains("victim") && $0.contains("symlink") })
        XCTAssertEqual(result.skillsRemoved, 0)        // row preserved, not deleted on a symlink
        XCTAssertEqual(result.skillsUpdated, 0)        // NOT read through / re-ingested
        let skills = try context.fetch(FetchDescriptor<Skill>())
        let victim = try XCTUnwrap(skills.first { $0.directoryName == "victim" })
        XCTAssertEqual(victim.name, "Original")        // NOT the out-of-store "Evil"
    }

    @MainActor
    func testRebuildSkipsRealpathEscapingSlugDirPreservingRow() throws {
        let context = try makeContext()
        // Ingest a real "victim" row plus a real sibling "decoy" skill dir inside the store.
        try writeSkillFile(slug: "victim", name: "Original", description: "orig")
        try writeSkillFile(slug: "decoy", name: "Decoy", description: "decoy")
        try writeManifest(skills: [overlay("victim"), overlay("decoy")])
        _ = service.rebuild(fromRoot: tempDir, context: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Skill>()).count, 2)

        // Replace victim's real slug dir with a symlink to the SIBLING slug dir: the target stays inside
        // the store yet realpath-escapes victim's canonical `skills/victim` position. The resolver must
        // still reject it, so the row is preserved and NOT re-ingested through the link.
        try FileManager.default.removeItem(atPath: tempDir + "/skills/victim")
        try FileManager.default.createSymbolicLink(
            atPath: tempDir + "/skills/victim", withDestinationPath: tempDir + "/skills/decoy")

        let result = service.rebuild(fromRoot: tempDir, context: context)

        XCTAssertTrue(result.warnings.contains { $0.contains("victim") && $0.contains("symlink") })
        XCTAssertEqual(result.skillsRemoved, 0)        // victim row preserved, never deleted
        let skills = try context.fetch(FetchDescriptor<Skill>())
        let victim = try XCTUnwrap(skills.first { $0.directoryName == "victim" })
        XCTAssertEqual(victim.name, "Original")        // NOT re-ingested as the sibling "Decoy"
    }
}
