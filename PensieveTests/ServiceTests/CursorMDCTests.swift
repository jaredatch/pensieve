import XCTest
@testable import Pensieve

final class CursorMDCTests: XCTestCase {
    func testGenerateGoldenString() {
        let config = CursorAdapterConfig(description: nil, globs: ["*.swift"], alwaysApply: false)
        let generated = CursorMDC.generate(
            directoryName: "x",
            description: "d",
            cursorConfig: config,
            body: "BODY"
        )

        XCTAssertEqual(generated, "---\n# pensieve: managed\ndescription: d\nglobs: *.swift\nalwaysApply: false\n---\n\nBODY\n")
    }

    func testDescriptionFallsBackAndEmptyDescriptionOmitsLine() {
        let fallback = CursorMDC.generate(
            directoryName: "x",
            description: "fallback",
            cursorConfig: CursorAdapterConfig(description: nil, globs: nil, alwaysApply: false),
            body: "BODY"
        )
        XCTAssertTrue(fallback.contains("description: fallback"))

        let empty = CursorMDC.generate(
            directoryName: "x",
            description: "",
            cursorConfig: CursorAdapterConfig(description: nil, globs: nil, alwaysApply: false),
            body: "BODY"
        )
        XCTAssertFalse(empty.contains("description:"))
        XCTAssertEqual(empty, "---\n# pensieve: managed\nalwaysApply: false\n---\n\nBODY\n")
    }

    func testConfigDescriptionOverridesSkillDescription() {
        let generated = CursorMDC.generate(
            directoryName: "x",
            description: "skill",
            cursorConfig: CursorAdapterConfig(description: "cfg", globs: nil, alwaysApply: false),
            body: "BODY"
        )

        XCTAssertTrue(generated.contains("description: cfg"))
        XCTAssertFalse(generated.contains("description: skill"))
    }

    func testCursorCompilerAdapterMatchesPureGenerator() {
        let config = CursorAdapterConfig(
            description: "TypeScript rules",
            globs: ["**/*.ts", "**/*.tsx"],
            alwaysApply: true
        )
        let skill = Skill(
            name: "TS Rules",
            skillDescription: "fallback",
            directoryName: "ts-rules",
            cursorConfig: config
        )
        let compiler = CursorCompiler(
            fileService: FileService(),
            skillStore: SkillStore(fileService: FileService(), baseDir: NSTemporaryDirectory())
        )
        let body = "# TS Rules"

        XCTAssertEqual(
            CursorMDC.generate(
                directoryName: skill.directoryName,
                description: skill.skillDescription,
                cursorConfig: skill.cursorConfig,
                body: body
            ),
            compiler.generateMDC(skill: skill, body: body)
        )
    }
}
