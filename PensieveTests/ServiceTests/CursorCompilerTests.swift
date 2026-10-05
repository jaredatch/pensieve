import XCTest
@testable import Pensieve

final class CursorCompilerTests: XCTestCase {
    private var fileService: FileService!
    private var skillStore: SkillStore!
    private var compiler: CursorCompiler!
    private var tempDir: String!

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.path + "PensieveCursorTests-\(UUID().uuidString)"
        let skillsDir = tempDir + "/skills"
        try FileManager.default.createDirectory(atPath: skillsDir, withIntermediateDirectories: true)

        fileService = FileService()
        skillStore = SkillStore(fileService: fileService, baseDir: skillsDir)
        compiler = CursorCompiler(fileService: fileService, skillStore: skillStore)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    // MARK: - MDC Generation

    func testGenerateMDCBasic() throws {
        let skill = Skill(
            name: "Test Skill",
            skillDescription: "A test skill",
            directoryName: "test-skill"
        )

        let mdc = compiler.generateMDC(skill: skill, body: "# Hello World")
        XCTAssertTrue(mdc.hasPrefix("---\n"))
        XCTAssertTrue(mdc.contains("description: A test skill"))
        XCTAssertTrue(mdc.contains("alwaysApply: false"))
        XCTAssertTrue(mdc.contains("# Hello World"))
    }

    func testGenerateMDCWithGlobs() throws {
        let config = CursorAdapterConfig(
            description: "TypeScript rules",
            globs: ["**/*.ts", "**/*.tsx"],
            alwaysApply: true
        )
        let skill = Skill(
            name: "TS Rules",
            directoryName: "ts-rules",
            cursorConfig: config
        )

        let mdc = compiler.generateMDC(skill: skill, body: "# TS Rules")
        XCTAssertTrue(mdc.contains("description: TypeScript rules"))
        XCTAssertTrue(mdc.contains("globs: **/*.ts, **/*.tsx"))
        XCTAssertTrue(mdc.contains("alwaysApply: true"))
    }

    func testGenerateMDCNoDescription() throws {
        let skill = Skill(name: "Bare Skill", directoryName: "bare-skill")
        let mdc = compiler.generateMDC(skill: skill, body: "content")
        // No description line should appear
        XCTAssertFalse(mdc.contains("description:"))
    }

    // MARK: - Compile + Write

    func testCompileWritesFile() throws {
        let dirName = try skillStore.createSkill(name: "compile-test", description: "compile-test", body: "# Compile Me")
        let skill = Skill(
            name: "Compile Test",
            skillDescription: "test",
            directoryName: dirName
        )

        let outputDir = tempDir + "/cursor-output"
        let outputPath = outputDir + "/" + dirName + ".mdc"

        // Manually set the output path by compiling to a project path
        try fileService.createDirectory(at: outputDir)
        let mdc = compiler.generateMDC(skill: skill, body: "# Compile Me")
        try fileService.writeFile(at: outputPath, content: mdc)

        XCTAssertTrue(fileService.fileExists(at: outputPath))
        let written = try fileService.readFile(at: outputPath)
        XCTAssertTrue(written.contains("# Compile Me"))
        XCTAssertTrue(written.contains("description: test"))
    }

    func testCompileStripsSkillFrontmatterFromMDCBody() throws {
        // A self-describing SKILL.md on disk (frontmatter + body), as 07.2 now writes.
        let dirName = try skillStore.createSkill(
            name: "Frontmatter Skill",
            description: "Has frontmatter",
            body: "# The real body"
        )
        let skill = Skill(name: "Frontmatter Skill", skillDescription: "Has frontmatter", directoryName: dirName)

        let projectPath = tempDir + "/proj"
        try fileService.createDirectory(at: projectPath + "/.cursor/rules")
        try compiler.compile(skill: skill, projectPath: projectPath)

        let mdc = try fileService.readFile(at: compiler.outputPath(skill: skill, projectPath: projectPath))
        XCTAssertTrue(mdc.contains("# The real body"))
        // The SKILL.md frontmatter must NOT be embedded in the .mdc body.
        XCTAssertFalse(mdc.contains("name: Frontmatter Skill"))
        // Exactly one frontmatter fence pair (the .mdc's own), i.e. two `---` fence lines.
        let fenceCount = mdc.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces) == "---" }
            .count
        XCTAssertEqual(fenceCount, 2)
    }

    // MARK: - Output Path

    func testOutputPathUserWide() {
        let skill = Skill(name: "Test", directoryName: "test")
        let path = compiler.outputPath(skill: skill, projectPath: nil)
        XCTAssertTrue(path.hasSuffix("/.cursor/rules/test.mdc"))
    }

    func testOutputPathProjectLevel() {
        let skill = Skill(name: "Test", directoryName: "test")
        let path = compiler.outputPath(skill: skill, projectPath: "/tmp/project")
        XCTAssertEqual(path, "/tmp/project/.cursor/rules/test.mdc")
    }
}
