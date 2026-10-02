import XCTest
@testable import Pensieve

extension UpstreamHistoryServiceTests {
    func testGlobMagicPathIsReadLiterally() throws {
        try assertLiteralHistory(path: ":(glob)x", decoyPath: "x")
    }

    func testExclusionMagicPathIsReadLiterally() throws {
        try assertLiteralHistory(path: ":!x", decoyPath: "other")
    }

    func testWildcardPathIsReadLiterally() throws {
        try assertLiteralHistory(path: "skills/*", decoyPath: "skills/other")
    }

    func testBracketGlobPathIsReadLiterally() throws {
        try assertLiteralHistory(path: "skills/[ab]", decoyPath: "skills/a")
    }

    private func assertLiteralHistory(
        path: String,
        decoyPath: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let repository = try makeRepository()
        try write(path + "/SKILL.md", text: "literal\n", in: repository)
        try write(decoyPath + "/SKILL.md", text: "decoy one\n", in: repository)
        let installed = try commit(repository, message: "create literal", timestamp: 1_700_013_001)
        try write(decoyPath + "/SKILL.md", text: "decoy two\n", in: repository)
        _ = try commit(repository, message: "change decoy", timestamp: 1_700_013_002)
        try write("SKILL.md", text: "literal\n", in: localDirectory)

        let result = try service().read(
            origin: origin(
                repo: URL(fileURLWithPath: repository).absoluteString,
                path: path,
                installedCommit: installed,
                contentHash: try stableHash(at: localDirectory)
            ),
            localDirectory: localDirectory
        )

        XCTAssertEqual(result.rows.map(\.sha), [installed], file: file, line: line)
        XCTAssertEqual(result.installedPosition, .at(sha: installed), file: file, line: line)
        XCTAssertEqual(
            result.installedBaseline?.files?.map(\.path),
            ["SKILL.md"],
            file: file,
            line: line
        )
        XCTAssertEqual(result.localEdits, .none, file: file, line: line)
    }
}
