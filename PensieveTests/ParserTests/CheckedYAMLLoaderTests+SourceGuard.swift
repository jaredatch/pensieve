import XCTest
@testable import Pensieve

extension CheckedYAMLLoaderTests {
    /// Enforces checked YAML loading with 38.2-e's load, compose, decoder, constructor and node-value patterns,
    /// widened to unqualified stream calls, Yams Parser type references and CYaml references.
    /// Load/compose calls may contain whitespace and line breaks between their tokens.
    /// Constructor calls also allow whitespace and line breaks before the opening parenthesis.
    /// Yams imports admit attributes, declaration kinds, indentation and line breaks, but
    /// `import /* x */ Yams` is not recognized. CYaml token matching also catches imports with intervening comments.
    /// Comments and strings are included, except standalone line comments for bare Parser.
    /// Only the exact loader path is exempt. This textual audit checks ordinary code, not
    /// deliberately hidden calls; it is not a Swift syntax parser.
    func testAppYAMLReadsUseCheckedLoader() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileService = FileService()
        let paths = try swiftSourcePaths(in: "Pensieve", root: sourceRoot, fileService: fileService)
            .filter { $0 != "Pensieve/Services/CheckedYAMLLoader.swift" }
        XCTAssertFalse(paths.isEmpty, "No Swift sources found under \(sourceRoot.path)/Pensieve")

        // Preserve 38.2-e's direct patterns and widen its imported-file coverage.
        let direct = try NSRegularExpression(
            pattern: #"Yams\s*\.\s*(load|load_all|compose|compose_all)\s*\(|YAMLDecoder|Constructor\s*\("#
                + #"|Yams\s*\.\s*`?Parser\b|\bCYaml\b"#
        )
        let imported = try NSRegularExpression(
            pattern: #"\.any([^A-Za-z0-9_]|$)|(?<![A-Za-z0-9_.])(load|load_all|compose|compose_all)\s*\(\s*yaml\s*:"#
                + #"|^(?![ \t]*//).*\bParser\b"#,
            options: .anchorsMatchLines
        )
        // Keep the original Yams prefix match while admitting more import spellings.
        let yamsImport = try NSRegularExpression(
            pattern: #"\bimport\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?`?Yams"#
        )
        for path in paths.sorted() {
            let source = try fileService.readFile(at: sourceRoot.appendingPathComponent(path).path)
            let lines = source.components(separatedBy: "\n")
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            var matches = direct.matches(in: source, range: range)
            if yamsImport.firstMatch(in: source, range: range) != nil {
                matches += imported.matches(in: source, range: range)
            }
            let text = source as NSString
            let lineNumbers = Set(matches.map {
                text.substring(to: $0.range.location).components(separatedBy: "\n").count
            })
            for lineNumber in lineNumbers.sorted() {
                XCTFail("\(path):\(lineNumber): use CheckedYAMLLoader for YAML reads: \(lines[lineNumber - 1])")
            }
        }
    }

    private func swiftSourcePaths(
        in directory: String,
        root: URL,
        fileService: FileServiceProtocol
    ) throws -> [String] {
        var paths: [String] = []
        for name in try fileService.listDirectory(at: root.appendingPathComponent(directory).path) {
            let relativePath = directory + "/" + name
            let path = root.appendingPathComponent(relativePath).path
            if fileService.directoryExists(at: path) {
                paths += try swiftSourcePaths(in: relativePath, root: root, fileService: fileService)
            } else if name.hasSuffix(".swift") {
                paths.append(relativePath)
            }
        }
        return paths
    }
}
