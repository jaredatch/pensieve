import XCTest
@testable import Pensieve

final class CursorOwnershipTests: XCTestCase {
    var root = ""
    var files = FileService()
    var mapped: LinkServiceCanonicalDirectoryFileService!
    var store: SkillStore!
    var compiler: CursorCompiler!
    var skill: Skill!

    override func setUpWithError() throws {
        root = TestTemporaryDirectory.path + "CursorOwnership-\(UUID().uuidString)"
        store = SkillStore(fileService: files, baseDir: root + "/store/skills")
        let slug = try store.createSkill(name: "Owned", description: "Description", body: "# Body")
        skill = Skill(name: "Owned", skillDescription: "Description", directoryName: slug)
        let mappings: [(logical: String, physical: String)] = [
            (TestPaths.skillsDir, root + "/store/skills"),
            (TestPaths.deployPaths.cursorUserRulesDirectory, root + "/user/rules")
        ] + PlatformTarget.allCases.compactMap { platform in
            TestPaths.deployPaths.userSkillsRoot(for: platform).map { ($0, root + "/user/" + platform.rawValue) }
        }
        mapped = LinkServiceCanonicalDirectoryFileService(wrapped: files, pathMappings: mappings, physicalSandbox: root)
        compiler = CursorCompiler(fileService: mapped, skillStore: store,
            userRulesDirectory: TestPaths.deployPaths.cursorUserRulesDirectory)
        try files.createDirectory(at: root + "/project")
    }

    override func tearDownWithError() throws { try files.deleteDirectory(at: root) }

    func testForeignRuleDeployAndRemovalPreserveBytesInBothScopes() throws {
        for project: String? in [nil, root + "/project"] {
            let path = compiler.outputPath(skill: skill, projectPath: project)
            let original = "---\ndescription: User rule\nalwaysApply: true\n---\n\nKeep my bytes.\n"
            try mapped.writeFile(at: path, content: original)
            XCTAssertThrowsError(try compiler.compile(skill: skill, projectPath: project)) { error in
                XCTAssertTrue(error.localizedDescription.contains(path))
            }
            XCTAssertEqual(try mapped.readFile(at: path), original)
            try compiler.remove(skill: skill, projectPath: project)
            XCTAssertEqual(try mapped.readFile(at: path), original)
        }
    }

    func testNewAndRedeployedRulesKeepMarkAndChangeBodyAndSettings() throws {
        for project: String? in [nil, root + "/project"] {
            skill.cursorConfig = nil
            try store.writeBody(directoryName: skill.directoryName, body: "# Body")
            let path = compiler.outputPath(skill: skill, projectPath: project)
            try compiler.compile(skill: skill, projectPath: project)
            XCTAssertEqual(try mapped.readFile(at: path),
                           "---\n# pensieve: managed\ndescription: Description\nalwaysApply: false\n---\n\n# Body\n")
            try store.writeBody(directoryName: skill.directoryName, body: "# Changed")
            skill.cursorConfig = CursorAdapterConfig(description: "Configured", globs: ["*.swift"], alwaysApply: true)
            try compiler.compile(skill: skill, projectPath: project)
            XCTAssertEqual(try mapped.readFile(at: path),
                           "---\n# pensieve: managed\ndescription: Configured\nglobs: *.swift\n"
                            + "alwaysApply: true\n---\n\n# Changed\n")
        }
    }

    func testExactLegacyIsAdoptedAndRemovedButOneByteDifferenceIsForeign() throws {
        let legacy = "---\ndescription: Description\nalwaysApply: false\n---\n\n# Body\n"
        try store.writeBody(directoryName: skill.directoryName, body: "# Body")
        for project: String? in [nil, root + "/project"] {
            let path = compiler.outputPath(skill: skill, projectPath: project)
            try mapped.writeFile(at: path, content: legacy)
            try compiler.compile(skill: skill, projectPath: project)
            XCTAssertEqual(try mapped.readFile(at: path), legacy.replacingOccurrences(of: "---\ndescription:",
                with: "---\n# pensieve: managed\ndescription:"))
            try mapped.writeFile(at: path, content: legacy)
            try compiler.remove(skill: skill, projectPath: project)
            XCTAssertFalse(try mapped.entryExistsWithoutFollowingLinks(at: path))
            for different in [legacy + "x", legacy.replacingOccurrences(of: "Body", with: "Bodx")] {
                try mapped.writeFile(at: path, content: different)
                XCTAssertThrowsError(try compiler.compile(skill: skill, projectPath: project)) { error in
                    guard case ArtifactOwnershipError.occupiedPath(let occupied) = error else {
                        return XCTFail("Expected occupied path, got \(error)")
                    }
                    XCTAssertEqual(occupied, path)
                }
                try compiler.remove(skill: skill, projectPath: project)
                XCTAssertEqual(try mapped.readFile(at: path), different)
            }
        }
    }

    func testMarkedRuleRemovalDoesNotNeedSourceSkill() throws {
        let path = compiler.outputPath(skill: skill, projectPath: root + "/project")
        try mapped.writeFile(at: path, content: "---\n# pensieve: managed\n---\nStale body")
        try store.deleteSkill(directoryName: skill.directoryName)
        try compiler.remove(skill: skill, projectPath: root + "/project")
        XCTAssertFalse(try mapped.entryExistsWithoutFollowingLinks(at: path))
    }
}
