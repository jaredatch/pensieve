import XCTest
@testable import Pensieve

/// Observable admission and ownership at the filesystem-facing owners; no injected guard answers.
final class PathGuardTests: XCTestCase {
    func testJoiningScalarsKeepSeparatorsAndComponentRulesAtAdmissionBoundaries() throws {
        for (index, scalar) in PathJoiningScalars.values.enumerated() {
            let name = scalar + "name"
            XCTAssertNoThrow(try LinkService.validatePathComponent(name))
            XCTAssertThrowsError(try LinkService.validatePathComponent("parent/" + name))
            XCTAssertThrowsError(try LinkService.validatePathComponent("~" + name))
            XCTAssertFalse(SkillStore.isPathSafeSlug("parent/" + name))
            XCTAssertNil(SkillStore.skillDirectoryPath(slug: "parent/" + name, base: "/store"))
            XCTAssertFalse(SkillStore.isCanonicalSlug(name), "Canonical naming policy stays unchanged")
            XCTAssertTrue(SkillStore.isPathSafeSlug(name))
            XCTAssertTrue(ProjectDirectory.canAccess("/" + name))
            XCTAssertFalse(ProjectDirectory.canAccess(name))
            let waiting = WaitingRemoval(source: "fixture", projectPath: "/" + name, projectName: name,
                projectIdentityKey: nil, artifactPath: "/" + name + "/.claude/skills/skill",
                platform: .claudeCode, slug: "skill", legacyFingerprint: nil)
            XCTAssertTrue(waiting.isValid)
            let record = DeployStateRecord(slug: "caf\u{00E9}", platform: PlatformTarget.claudeCode.rawValue,
                scope: "project", projectIdentityKey: nil,
                artifactPath: "/" + name + "/.claude/skills/cafe\u{0301}", recordedAt: "fixture")
            XCTAssertEqual(record.projectReference, "/" + name)
            XCTAssertFalse(InstallRelativePathPolicy.isValid("/" + name))
            XCTAssertTrue(InstallRelativePathPolicy.isValid("folder/" + name))
            XCTAssertFalse(InstallRelativePathPolicy.isValid("folder/" + scalar + "/../name"))
            XCTAssertEqual(HomePath.displayAbbreviation("/home/" + name, homeDirectory: "/home"), "~/" + name)
            XCTAssertEqual(HomePath.normalizedAbbreviation("/home/" + name + "/../file", homeDirectory: "/home"), "~/file")
            XCTAssertNil(HomePath.displayAbbreviation("/home-other/" + name, homeDirectory: "/home"))
            XCTAssertEqual(EditorAssetResolver.resolve(root: URL(fileURLWithPath: "/assets"),
                                                       requestPath: name)?.path, "/assets/" + name)
            XCTAssertEqual(SkillPreviewLinkPolicy.decision(for: try XCTUnwrap(URL(string: name + ".md")),
                documentRelativePath: "SKILL.md", files: [name + ".md"]),
                [0, 3].contains(index) ? .selectFile(name + ".md") : .ignore)
            XCTAssertEqual(SkillPreviewLinkPolicy.decision(for: try XCTUnwrap(URL(string: "/" + name + ".md")),
                documentRelativePath: "SKILL.md", files: [name + ".md"]), .ignore)
        }
    }

    func testJoiningNamesAndDecomposedStoreTargetsStayOwnedWithoutAdmittingTraversal() throws {
        let root = TestTemporaryDirectory.path + "PathOwnership-" + UUID().uuidString
        let files = FileService()
        defer { try? files.deleteDirectory(at: root) }
        let store = root + "/caf\u{00E9}/skills"
        let ownership = DeployArtifactOwnership(fileService: files)
        for (index, name) in (PathJoiningScalars.values.map { $0 + "name" } + ["caf\u{00E9}", "cafe\u{0301}"]).enumerated() {
            for linksFile in [false, true] {
                let link = root + "/link-\(index)-\(linksFile)"
                let target = (store + "/" + name + (linksFile ? "/SKILL.md" : "")).decomposedStringWithCanonicalMapping
                try files.createSymlink(at: link, pointingTo: target)
                XCTAssertEqual(try ownership.link(at: link, skillsDirectory: store, linksFile: linksFile), .owned)
                try files.deleteFile(at: link)
                try files.createSymlink(at: link, pointingTo: store + "/" + name + "/../foreign")
                XCTAssertEqual(try ownership.link(at: link, skillsDirectory: store, linksFile: linksFile), .foreignLink)
            }
        }
    }

    func testProjectWriterRetainsJoiningNamesAndRejectsOutsideOrTraversingPaths() throws {
        let root = TestTemporaryDirectory.path + "PathWriter-" + UUID().uuidString
        let files = FileService()
        defer { try? files.deleteDirectory(at: root) }
        try files.createDirectory(at: root)
        for scalar in PathJoiningScalars.values {
            let name = scalar + "folder"
            let path = root + "/" + name + "/body.txt"
            try files.writeFileInProject(at: path, content: "body", projectPath: root)
            XCTAssertEqual(try files.readFile(at: path), "body")
            XCTAssertThrowsError(try files.writeFileInProject(at: root + "/" + name + "/../escape",
                                                             content: "bad", projectPath: root))
            XCTAssertThrowsError(try files.writeFileInProject(at: root + "-other/" + name,
                                                             content: "bad", projectPath: root))
        }
    }
}
