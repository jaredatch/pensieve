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
        try writeSkillFile(slug: "victim", name: "Original", description: "orig")
        try writeManifest(skills: [overlay("victim")])
        _ = service.rebuild(fromRoot: tempDir, context: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Skill>()).count, 1)
        let outside = tempDir + "/outside"
        let evil = SkillSerializer.serialize(name: "Evil", description: "pwned", body: "# evil")
        try fileService.writeFile(at: outside + "/SKILL.md", content: evil)
        let swapping = StoreDirectorySwapFileService(
            wrapped: fileService, directory: tempDir + "/skills/victim", outsideDirectory: outside)
        let service = StoreRebuildService(fileService: swapping, manifestService: manifest)

        let result = service.rebuild(fromRoot: tempDir, context: context)

        XCTAssertNil(swapping.swapError)
        XCTAssertGreaterThan(swapping.swapCount, 0, "The fixture must swap a real directory after its type probe")
        XCTAssertTrue(result.warnings.contains { $0.contains("victim") && $0.contains("symlink") })
        XCTAssertEqual(result.skillsRemoved, 0, "A realpath escape must preserve the existing row")
        XCTAssertEqual(result.skillsUpdated, 0, "Rebuild must not ingest the outside skill")
        let skills = try context.fetch(FetchDescriptor<Skill>())
        XCTAssertEqual(skills.count, 1)
        let victim = try XCTUnwrap(skills.first { $0.directoryName == "victim" })
        XCTAssertEqual(victim.name, "Original", "Rebuild must preserve the original identity")
        XCTAssertEqual(victim.skillDescription, "orig")
        XCTAssertEqual(try fileService.readFile(at: outside + "/SKILL.md"), evil)
    }
}
