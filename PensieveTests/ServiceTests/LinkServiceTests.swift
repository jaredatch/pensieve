import XCTest
@testable import Pensieve

final class LinkServiceTests: XCTestCase {
    var fileService: FileService!
    var linkService: LinkService!
    var tempDir: String!
    private var skillsDir: String!

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.path + "PensieveLinkTests-\(UUID().uuidString)"
        skillsDir = tempDir + "/pensieve-skills"
        try FileManager.default.createDirectory(atPath: skillsDir, withIntermediateDirectories: true)

        fileService = FileService()
        linkService = LinkService(fileService: fileService)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    // MARK: - Helpers

    func makeSkill(name: String = "test-skill", dirName: String = "test-skill") -> Skill {
        Skill(name: name, directoryName: dirName)
    }

    private func createSkillOnDisk(dirName: String, body: String = "# Test") throws {
        let dir = skillsDir + "/" + dirName
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try body.write(toFile: dir + "/SKILL.md", atomically: true, encoding: .utf8)
    }

    // MARK: - Link Path Tests

    func testClaudeCodeUserWideLinkPath() {
        let skill = makeSkill()
        let path = linkService.linkPath(skill: skill, platform: .claudeCode, projectPath: nil)
        XCTAssertTrue(path.hasSuffix("/.claude/skills/test-skill"))
    }

    func testClaudeCodeProjectLinkPath() {
        let skill = makeSkill()
        let path = linkService.linkPath(skill: skill, platform: .claudeCode, projectPath: "/tmp/project")
        XCTAssertEqual(path, "/tmp/project/.claude/skills/test-skill")
    }

    func testGrokUserWideLinkPath() {
        let skill = makeSkill()
        let path = linkService.linkPath(skill: skill, platform: .grok, projectPath: nil)
        XCTAssertTrue(path.hasSuffix("/.grok/skills/test-skill"))
    }

    func testGrokProjectScopedLinkPath() {
        let skill = makeSkill()
        let path = linkService.linkPath(skill: skill, platform: .grok, projectPath: "/tmp/project")
        XCTAssertEqual(path, "/tmp/project/.grok/skills/test-skill")
    }

    func testCodexProjectLinkPath() {
        let skill = makeSkill()
        let path = linkService.linkPath(skill: skill, platform: .codex, projectPath: "/tmp/project")
        XCTAssertEqual(path, "/tmp/project/agents/test-skill.md")
    }

    func testCodexUserWideLinkPathUsesOwnDirectory() {
        let skill = makeSkill()
        let path = linkService.linkPath(skill: skill, platform: .codex, projectPath: nil)
        XCTAssertTrue(path.hasSuffix("/.codex/skills/test-skill"))
        XCTAssertFalse(path.contains("/.claude/"))
    }

    func testOpenClawUserWideLinkPath() {
        let skill = makeSkill()
        let path = linkService.linkPath(skill: skill, platform: .openClaw, projectPath: nil)
        XCTAssertTrue(path.hasSuffix("/.openclaw/skills/test-skill"))
    }

    func testHermesUserWideLinkPath() {
        let skill = makeSkill()
        let path = linkService.linkPath(skill: skill, platform: .hermes, projectPath: nil)
        XCTAssertTrue(path.hasSuffix("/.hermes/skills/pensieve/test-skill"))
    }

    // MARK: - Target Path Tests

    func testClaudeCodeTargetPath() {
        let skill = makeSkill()
        let target = linkService.targetPath(skill: skill, platform: .claudeCode, projectPath: nil)
        XCTAssertTrue(target.hasSuffix("/.pensieve/skills/test-skill"))
    }

    func testGrokTargetPathIsCanonicalSkillDirectory() {
        let skill = makeSkill()
        let target = linkService.targetPath(skill: skill, platform: .grok, projectPath: "/tmp/project")
        XCTAssertEqual(target, PathConstants.pensieveSkillsDir + "/test-skill")
        XCTAssertFalse(target.hasSuffix("/SKILL.md"))
    }

    func testCodexUserWideTargetPathIsDirectory() {
        let skill = makeSkill()
        let target = linkService.targetPath(skill: skill, platform: .codex, projectPath: nil)
        XCTAssertTrue(target.hasSuffix("/.pensieve/skills/test-skill"))
        XCTAssertFalse(target.hasSuffix("/SKILL.md"))
    }

    func testCodexProjectTargetPathIsSkillFile() {
        let skill = makeSkill()
        let target = linkService.targetPath(skill: skill, platform: .codex, projectPath: "/x")
        XCTAssertTrue(target.hasSuffix("/.pensieve/skills/test-skill/SKILL.md"))
    }

    func testOpenClawTargetPathIsDirectory() {
        let skill = makeSkill()
        let target = linkService.targetPath(skill: skill, platform: .openClaw, projectPath: nil)
        XCTAssertTrue(target.hasSuffix("/.pensieve/skills/test-skill"))
        XCTAssertFalse(target.hasSuffix("/SKILL.md"))
    }

    func testHermesTargetPathIsDirectory() {
        let skill = makeSkill()
        let target = linkService.targetPath(skill: skill, platform: .hermes, projectPath: nil)
        XCTAssertTrue(target.hasSuffix("/.pensieve/skills/test-skill"))
        XCTAssertFalse(target.hasSuffix("/SKILL.md"))
    }

    // MARK: - Symlink Integration Tests

    func testCreateAndValidateSymlink() throws {
        try createSkillOnDisk(dirName: "test-skill")

        let linkPath = tempDir + "/claude-skills/test-skill"
        let targetPath = skillsDir + "/test-skill"

        try fileService.createSymlink(at: linkPath, pointingTo: targetPath)

        XCTAssertTrue(fileService.isSymlink(at: linkPath))
        let resolvedTarget = try fileService.symlinkTarget(at: linkPath)
        XCTAssertEqual(resolvedTarget, targetPath)

        // Verify we can read through the symlink
        let body = try fileService.readFile(at: linkPath + "/SKILL.md")
        XCTAssertEqual(body, "# Test")
    }

    func testCreateSymlinkReplacesStale() throws {
        try createSkillOnDisk(dirName: "test-skill")

        let linkPath = tempDir + "/stale-link"
        let staleTarget = tempDir + "/nonexistent"
        let correctTarget = skillsDir + "/test-skill"

        // Create a stale symlink
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: staleTarget)
        XCTAssertTrue(fileService.isSymlink(at: linkPath))

        // createSymlink should replace it
        try fileService.createSymlink(at: linkPath, pointingTo: correctTarget)
        let resolved = try fileService.symlinkTarget(at: linkPath)
        XCTAssertEqual(resolved, correctTarget)
    }

    // MARK: - Platform Rejection

    func testCursorRejectsSymlink() {
        let skill = makeSkill()
        XCTAssertThrowsError(try linkService.link(skill: skill, platform: .cursor, projectPath: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("compiled output"))
        }
    }

    func testSupportsProjectScopePartitionsPlatforms() {
        XCTAssertTrue(PlatformTarget.claudeCode.supportsProjectScope)
        XCTAssertTrue(PlatformTarget.grok.supportsProjectScope)
        XCTAssertTrue(PlatformTarget.codex.supportsProjectScope)
        XCTAssertTrue(PlatformTarget.cursor.supportsProjectScope)
        XCTAssertFalse(PlatformTarget.openClaw.supportsProjectScope)
        XCTAssertFalse(PlatformTarget.hermes.supportsProjectScope)
    }

    func testGrokUsesSymlinks() {
        XCTAssertTrue(PlatformTarget.grok.usesSymlinks)
    }

    func testGrokSupportsProjectScope() {
        XCTAssertTrue(PlatformTarget.grok.supportsProjectScope)
    }

    func testOpenClawProjectScopeThrowsTypedError() {
        let skill = makeSkill()
        XCTAssertThrowsError(try linkService.link(skill: skill, platform: .openClaw, projectPath: "/x")) { error in
            guard case LinkError.projectScopeUnsupported(.openClaw) = error else {
                return XCTFail("Expected OpenClaw project-scope unsupported error, got \(error)")
            }
        }
    }

    func testHermesProjectScopeThrowsTypedError() {
        let skill = makeSkill()
        XCTAssertThrowsError(try linkService.link(skill: skill, platform: .hermes, projectPath: "/x")) { error in
            guard case LinkError.projectScopeUnsupported(.hermes) = error else {
                return XCTFail("Expected Hermes project-scope unsupported error, got \(error)")
            }
        }
    }

    func testClaudeCodeProjectScopeDoesNotThrowUnsupportedScope() {
        let skill = makeSkill(dirName: "missing-\(UUID().uuidString)")
        XCTAssertThrowsError(try linkService.link(skill: skill, platform: .claudeCode, projectPath: "/x")) { error in
            if case LinkError.projectScopeUnsupported = error {
                XCTFail("Claude Code project deploy must not trip the unsupported-scope guard")
            }
        }
    }

    // MARK: - Path Component Validation

    func testValidatePathComponentRejectsUnsafeComponents() {
        XCTAssertThrowsError(try LinkService.validatePathComponent(".."))
        XCTAssertThrowsError(try LinkService.validatePathComponent("."))
        XCTAssertThrowsError(try LinkService.validatePathComponent("a/b"))
        XCTAssertThrowsError(try LinkService.validatePathComponent("/abs"))
        XCTAssertThrowsError(try LinkService.validatePathComponent("~bad"))
        XCTAssertThrowsError(try LinkService.validatePathComponent(""))
    }

    func testValidatePathComponentAcceptsNormalSlug() {
        XCTAssertNoThrow(try LinkService.validatePathComponent("my-skill"))
    }

    // MARK: - Boundary enforcement (validator is called before any filesystem mutation)

    /// A spy FileService that records whether the symlink/delete mutations were attempted.
    /// `directoryExists`/`isSymlink`/`fileExists` return true so link()/unlink() WOULD reach
    /// their mutation if the validator were not enforced first.
    private final class SpyFileService: FileServiceProtocol {
        private(set) var createSymlinkCalled = false
        private(set) var deleteFileCalled = false

        func readFile(at path: String) throws -> String { "" }
        func writeFile(at path: String, content: String) throws {}
        func deleteFile(at path: String) throws { deleteFileCalled = true }
        func fileExists(at path: String) -> Bool { true }
        func isExecutableFile(at path: String) -> Bool { true }
        func directoryExists(at path: String) -> Bool { true }
        func createDirectory(at path: String) throws {}
        func deleteDirectory(at path: String) throws {}
        func createSymlink(at linkPath: String, pointingTo targetPath: String) throws { createSymlinkCalled = true }
        func symlinkTarget(at path: String) throws -> String { "" }
        func isSymlink(at path: String) -> Bool { true }
        func listDirectory(at path: String) throws -> [String] { [] }
        func contentsHash(at path: String) throws -> String { "" }
    }

    func testLinkEnforcesPathComponentBeforeSymlink() {
        let spy = SpyFileService()
        let service = LinkService(fileService: spy)
        let skill = makeSkill(name: "evil", dirName: "../evil")
        XCTAssertThrowsError(try service.link(skill: skill, platform: .openClaw, projectPath: nil)) { error in
            guard case LinkError.invalidPathComponent = error else {
                return XCTFail("Expected invalidPathComponent, got \(error)")
            }
        }
        XCTAssertFalse(spy.createSymlinkCalled, "link() must validate the path component before creating a symlink")
    }

    func testUnlinkEnforcesPathComponentBeforeDelete() {
        let spy = SpyFileService()
        let service = LinkService(fileService: spy)
        let skill = makeSkill(name: "evil", dirName: "../evil")
        XCTAssertThrowsError(try service.unlink(skill: skill, platform: .openClaw, projectPath: nil)) { error in
            guard case LinkError.invalidPathComponent = error else {
                return XCTFail("Expected invalidPathComponent, got \(error)")
            }
        }
        XCTAssertFalse(spy.deleteFileCalled, "unlink() must validate the path component before deleting")
    }
}
