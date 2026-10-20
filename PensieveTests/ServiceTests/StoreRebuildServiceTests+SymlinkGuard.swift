import SwiftData
import XCTest
@testable import Pensieve

extension StoreRebuildServiceTests {
    @MainActor
    func testLinkedStoreContainersRefuseIngestWithoutChangingRows() throws {
        try writeSkillFile(slug: "victim", name: "Original", description: "Original")
        try writeManifest(skills: [overlay("victim")])
        let snapshot = try manifest.read(fromRoot: tempDir)
        for container in ["skills", "manifest"] {
            let path = tempDir + "/" + container
            let outside = tempDir + "/outside-" + container
            try FileManager.default.moveItem(atPath: path, toPath: outside)
            try fileService.createSymlink(at: path, pointingTo: outside)
            for suppliedSnapshot in [false, true] {
                let context = try makeContext()
                context.insert(Skill(name: "Preserved", skillDescription: "Local", directoryName: "victim"))
                context.insert(Skill(name: "Absent", skillDescription: "Local", directoryName: "absent"))
                context.insert(Pensieve.Category(name: "Preserved category"))
                try context.save()
                let result = suppliedSnapshot
                    ? service.rebuild(snapshot: snapshot, fromRoot: tempDir, context: context, manifestIsAuthoritative: true)
                    : service.rebuild(fromRoot: tempDir, context: context)
                XCTAssertTrue(result.ingestIncomplete || result.storeUnreadable, container)
                XCTAssertFalse(result.warnings.isEmpty, container)
                XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Skill>()).map(\.name)), ["Preserved", "Absent"])
                XCTAssertEqual(try context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name), ["Preserved category"])
            }
            try fileService.deleteFile(at: path)
            try FileManager.default.moveItem(atPath: outside, toPath: path)
        }
    }

    @MainActor
    func testLinkedAndRealStoreRebuildSameBodiesPreservedRowsAndWarnings() throws {
        let linked = tempDir + "/alias"
        try fileService.createSymlink(at: linked, pointingTo: tempDir)
        try writeSkillFile(slug: "good", name: "Good", description: "Description", body: "Good body")
        try writeSkillFile(slug: "unreadable", name: "Unreadable", description: "Description")
        try fileService.writeFile(at: tempDir + "/outside/SKILL.md", content:
            SkillSerializer.serialize(name: "Outside", description: "Forbidden", body: "Outside body"))
        try fileService.createSymlink(at: tempDir + "/skills/refused", pointingTo: tempDir + "/outside")
        try fileService.deleteFile(at: tempDir + "/skills/unreadable/SKILL.md")
        try fileService.createSymlink(at: tempDir + "/skills/unreadable/SKILL.md",
                                      pointingTo: tempDir + "/outside/SKILL.md")
        try fileService.writeData(at: tempDir + "/skills/bad-text/SKILL.md", data: Data([0xFF, 0xFE, 0xFF]))
        try writeManifest(skills: [overlay("good"), overlay("refused"), overlay("unreadable"), overlay("bad-text")])
        var warnings: [[String]] = []
        for root in [try XCTUnwrap(tempDir), linked] {
            let context = try makeContext()
            for slug in ["refused", "unreadable", "bad-text"] {
                context.insert(Skill(name: "Preserved " + slug, skillDescription: "Original", directoryName: slug))
            }
            try context.save()
            let result = service.rebuild(fromRoot: root, context: context)
            warnings.append(result.warnings.sorted())
            XCTAssertEqual(result.warnings.count, 3)
            XCTAssertTrue(result.warnings.contains { $0.contains("refused") && $0.contains("symlink") })
            XCTAssertTrue(result.warnings.contains { $0.contains("unreadable") && $0.contains("not a regular file") })
            XCTAssertTrue(result.warnings.contains { $0.contains("bad-text") && $0.contains("could not be read") })
            let skills = try context.fetch(FetchDescriptor<Skill>())
            XCTAssertEqual(Set(skills.map(\.name)),
                           ["Good", "Preserved refused", "Preserved unreadable", "Preserved bad-text"])
            let store = SkillStore(fileService: fileService, baseDir: root + "/skills", storeRoot: root)
            XCTAssertEqual(try store.readBody(directoryName: "good"),
                SkillSerializer.serialize(name: "Good", description: "Description", body: "Good body"))
            XCTAssertThrowsError(try store.readBody(directoryName: "refused"))
            XCTAssertThrowsError(try store.readBody(directoryName: "bad-text"))
        }
        XCTAssertEqual(warnings[0], warnings[1])
    }

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
        let fixtureRoot = try XCTUnwrap(tempDir)
        defer { tempDir = fixtureRoot }
        for linked in [false, true] {
            let real = fixtureRoot + "/store-\(linked)"
            try fileService.createDirectory(at: real)
            tempDir = linked ? fixtureRoot + "/linked-store" : real
            if linked { try fileService.createSymlink(at: tempDir, pointingTo: real) }
            try assertEscapingDirectoryPreservesRow()
        }
    }

    @MainActor
    private func assertEscapingDirectoryPreservesRow() throws {
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
