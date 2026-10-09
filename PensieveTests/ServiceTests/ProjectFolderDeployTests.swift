import Darwin
import XCTest
@testable import Pensieve

final class ProjectFolderDeployTests: XCTestCase {
    var root = ""
    let files = FileService()
    var mapped: LinkServiceCanonicalDirectoryFileService!
    var links: LinkService!
    var compiler: CursorCompiler!
    var skill: Skill!
    let platforms: [PlatformTarget] = [.claudeCode, .grok, .codex, .cursor]

    override func setUpWithError() throws {
        root = TestTemporaryDirectory.path + "ProjectFolderDeployTests-\(UUID().uuidString)"
        let store = SkillStore(fileService: files, baseDir: root + "/store", storeRoot: root + "/store")
        let slug = try store.createSkill(name: "test-skill", description: "Test", body: "# Body")
        skill = Skill(name: "Test", directoryName: slug)
        var mappings = [(logical: TestPaths.skillsDir, physical: root + "/store")]
        for platform in PlatformTarget.allCases where platform.usesSymlinks {
            if let logical = TestPaths.deployPaths.userSkillsRoot(for: platform) {
                let source = platform == .hermes
                    ? (logical as NSString).deletingLastPathComponent : logical
                mappings.append((logical: source, physical: root + "/user/" + platform.rawValue))
            }
        }
        mappings.append((logical: TestPaths.deployPaths.cursorUserRulesDirectory, physical: root + "/user/cursor"))
        mapped = LinkServiceCanonicalDirectoryFileService(
            wrapped: files, pathMappings: mappings, physicalSandbox: root)
        links = TestPaths.linkService(fileService: mapped)
        compiler = CursorCompiler(fileService: mapped, skillStore: store,
            userRulesDirectory: TestPaths.deployPaths.cursorUserRulesDirectory)
    }

    override func tearDownWithError() throws {
        if files.directoryExists(at: root) { try files.deleteDirectory(at: root) }
    }

    func deploy(_ platform: PlatformTarget, to project: String?) throws {
        if platform.usesSymlinks {
            try links.link(skill: skill, platform: platform, projectPath: project)
        } else {
            try compiler.compile(skill: skill, projectPath: project)
        }
    }

    func artifact(_ platform: PlatformTarget, in project: String) -> String {
        if platform.usesSymlinks {
            return links.linkPath(skill: skill, platform: platform, projectPath: project)
        }
        return compiler.outputPath(skill: skill, projectPath: project)
    }

    func assertMissing(_ platform: PlatformTarget, project: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try deploy(platform, to: project), file: file, line: line) { error in
            guard case ProjectFolderError.missing(let path) = error else {
                return XCTFail("Expected missing folder for \(platform), got \(error)", file: file, line: line)
            }
            XCTAssertEqual(path, project, file: file, line: line)
            XCTAssertTrue(error.localizedDescription.contains("folder is missing"), file: file, line: line)
            XCTAssertTrue(error.localizedDescription.contains(project), file: file, line: line)
        }
    }

    func testMissingProjectDoesNotCreateAnyAncestorForFourAgents() throws {
        for platform in platforms {
            let ancestor = root + "/missing-\(platform.rawValue)"
            let project = ancestor + "/nested/project"
            let before = try files.listDirectory(at: root)
            assertMissing(platform, project: project)
            XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: ancestor))
            XCTAssertEqual(try files.listDirectory(at: root), before)
        }
    }

    func testPlainFileProjectIsMissingAndUnchangedForFourAgents() throws {
        let project = root + "/project-file"
        try files.writeFile(at: project, content: "Keep these bytes")
        let identity = files.fileIdentity(at: project, followingLinks: false)
        let entries = try files.listDirectory(at: root).sorted()
        for platform in platforms {
            assertMissing(platform, project: project)
            XCTAssertEqual(try files.readFile(at: project), "Keep these bytes")
            XCTAssertEqual(files.fileIdentity(at: project, followingLinks: false), identity)
            XCTAssertEqual(try files.listDirectory(at: root).sorted(), entries)
        }
    }

    func testDanglingProjectLinkIsMissingAndUnchangedForFourAgents() throws {
        let project = root + "/project-link"
        let target = root + "/absent-target"
        try files.createSymlink(at: project, pointingTo: target)
        let entries = try files.listDirectory(at: root).sorted()
        for platform in platforms {
            assertMissing(platform, project: project)
            XCTAssertEqual(try files.symlinkTarget(at: project), target)
            XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: target))
            XCTAssertEqual(try files.listDirectory(at: root).sorted(), entries)
        }
    }

    func testProjectLinkToFileIsMissingAndUnchangedForFourAgents() throws {
        let target = root + "/target-file"
        let project = root + "/project-link"
        try files.writeFile(at: target, content: "Original")
        try files.createSymlink(at: project, pointingTo: target)
        let entries = try files.listDirectory(at: root).sorted()
        for platform in platforms {
            assertMissing(platform, project: project)
            XCTAssertEqual(try files.symlinkTarget(at: project), target)
            XCTAssertEqual(try files.readFile(at: target), "Original")
            XCTAssertEqual(try files.listDirectory(at: root).sorted(), entries)
        }
    }

    func testProjectLinkToDirectoryDeploysInsideTargetForFourAgents() throws {
        let target = root + "/target-directory"
        let project = root + "/project-link"
        try files.createDirectory(at: target)
        try files.createSymlink(at: project, pointingTo: target)
        for platform in platforms {
            try deploy(platform, to: project)
            let physicalArtifact = target + artifact(platform, in: project).dropFirst(project.count)
            XCTAssertTrue(try files.entryExistsWithoutFollowingLinks(at: physicalArtifact))
            XCTAssertEqual(try files.symlinkTarget(at: project), target)
            if platform.usesSymlinks {
                XCTAssertTrue(links.isLinked(skill: skill, platform: platform, projectPath: project))
            } else {
                XCTAssertTrue(compiler.isUpToDate(skill: skill, projectPath: project))
            }
        }
    }

    func testExistingEmptyProjectCreatesAgentFoldersForFourAgents() throws {
        for platform in platforms {
            let project = root + "/project-\(platform.rawValue)"
            try files.createDirectory(at: project)
            XCTAssertEqual(try files.listDirectory(at: project), [])
            try deploy(platform, to: project)
            XCTAssertTrue(try files.entryExistsWithoutFollowingLinks(at: artifact(platform, in: project)))
            if platform.usesSymlinks {
                XCTAssertTrue(links.isLinked(skill: skill, platform: platform, projectPath: project))
            } else {
                XCTAssertTrue(compiler.isUpToDate(skill: skill, projectPath: project))
            }
        }
    }

    func testUnreadableAncestorReportsCouldNotCheckForFourAgents() throws {
        let parent = root + "/denied"
        let project = parent + "/project"
        try files.createDirectory(at: project)
        XCTAssertEqual(chmod(parent, 0), 0)
        defer { XCTAssertEqual(chmod(parent, 0o700), 0) }
        for platform in platforms {
            XCTAssertThrowsError(try deploy(platform, to: project)) { error in
                guard case ProjectFolderError.couldNotCheck(let path, let reason) = error else {
                    return XCTFail("Expected couldn't-check error, got \(error)")
                }
                XCTAssertEqual(path, project)
                XCTAssertFalse(reason.isEmpty)
                XCTAssertTrue(error.localizedDescription.contains("couldn't be checked"))
            }
        }
        XCTAssertEqual(chmod(parent, 0o700), 0)
        XCTAssertEqual(try files.listDirectory(at: project), [])
    }

    func testUserWideDeployCreatesMissingFoldersForSixAgents() throws {
        for platform in PlatformTarget.allCases {
            let folder = root + "/user/" + platform.rawValue
            XCTAssertFalse(files.directoryExists(at: folder))
            try deploy(platform, to: nil)
            XCTAssertTrue(files.directoryExists(at: folder))
            let skillsFolder = platform == .hermes ? folder + "/" + Constants.hermesDefaultCategory : folder
            XCTAssertTrue(files.directoryExists(at: skillsFolder))
            let output = skillsFolder + "/" + skill.directoryName + (platform == .cursor ? ".mdc" : "")
            XCTAssertTrue(try files.entryExistsWithoutFollowingLinks(at: output))
        }
    }
}
