import XCTest
@testable import Pensieve

final class SkillRewriteRegressionTests: XCTestCase {
    private func rewrite(_ body: String, source: String) -> String {
        SkillSerializer.rewrite(
            body: body, preserving: SkillParser.parse(source), fallbackName: "A", fallbackDescription: "D"
        ).content
    }

    func testCRLFSavesConvertDraftBreaksToFileStyle() {
        let header = "---\r\nname: A\r\ndescription: D\r\nlicense: MIT\r\n---\r\n\r\n"
        XCTAssertEqual(rewrite("Edited\nSecond\rThird\r\nFourth", source: header + "Old\r\n"),
                       header + "Edited\r\nSecond\r\nThird\r\nFourth\r\n")
    }

    func testChangedDraftTerminalBreaksNeverAccumulate() {
        for ending in ["\n", "\r\n"] {
            let header = "---\(ending)name: A\(ending)description: D\(ending)---\(ending)\(ending)"
            for suffix in ["", ending, ending + ending + ending] {
                let expected = header + "Edited" + suffix
                var source = header + "Old" + suffix
                for draft in ["Edited\n", "Edited\r\n\r\n", "Edited\n\n\n"] {
                    source = rewrite(draft, source: source)
                    XCTAssertEqual(source, expected, "suffix: \(suffix.debugDescription)")
                }
            }
        }
    }

    func testBodyOnlySavesConvertBreaksAndKeepOnlySourceSuffix() {
        for ending in ["\n", "\r\n"] {
            for suffix in ["", ending, ending + ending] {
                let source = "Old\(ending)Body" + suffix
                let header = "---\(ending)name: A\(ending)description: D\(ending)---\(ending)\(ending)"
                let expected = header + "Edited" + ending + "Second" + suffix
                let first = rewrite("Edited\nSecond\r\n", source: source)
                XCTAssertEqual(first, expected)
                XCTAssertEqual(rewrite("Edited\nSecond\n\n", source: first), expected)
            }
        }
    }

    func testCanonicalNoOpDraftKeepsSourceAcrossRepeatedSaves() {
        for ending in ["\n", "\r\n"] {
            let source = "---\(ending)name: A\(ending)description: D\(ending)---\(ending)\(ending)Body\(ending)"
            var current = source
            for _ in 0..<3 {
                current = rewrite("\nBody\n\n", source: current)
                XCTAssertEqual(current, source)
            }
        }
    }

    func testOddFenceBreaksRemainBodyOnlyAndKeepSourceOnIdentityRewrite() throws {
        for ending in ["\r", "\u{85}", "\u{2028}", "\u{2029}"] {
            let sources = [
                "---\(ending)name: X\(ending)description: Y\(ending)---\(ending)body\(ending)",
                "---\(ending)name: X\ndescription: Y\n---\nbody\n"
            ]
            for source in sources {
                let parsed = SkillParser.parse(source)
                XCTAssertFalse(parsed.hasRequiredFrontmatter, ending.debugDescription)
                XCTAssertNil(parsed.preservedFile, ending.debugDescription)
                XCTAssertEqual(parsed.body, source)
                let normalized = try XCTUnwrap(SkillSerializer.normalizeIdentity(name: "A", description: "D", parsed: parsed))
                XCTAssertEqual(normalized, "---\nname: A\ndescription: D\n---\n\n" + source)
            }
        }
    }

    func testLSFenceInsideLFFencedFileCannotMoveBodyBoundary() throws {
        let yaml = "name: X\ndescription: |\n  a\u{2028}  ---\u{2028}  name: hidden\u{2028}  ---\u{2028}  end\nlicense: MIT"
        let header = "---\n" + yaml + "\n---\n\n"
        let source = header + "Body\n"
        let parsed = SkillParser.parse(source)
        let frontmatter = try XCTUnwrap(parsed.preservedFrontmatter)
        XCTAssertEqual(frontmatter.source, yaml)
        XCTAssertEqual(parsed.name, "X")
        let loaded = try CheckedYAMLLoader.load(yaml: yaml) as? [String: Any]
        XCTAssertEqual(parsed.description, loaded?["description"] as? String)
        XCTAssertFalse(frontmatter.entriesAreTrustworthy)
        XCTAssertEqual(SkillParser.stripFrontmatter(source), "Body")
        XCTAssertNil(SkillSerializer.normalizeIdentity(name: "A", description: "D", parsed: parsed))
        XCTAssertEqual(rewrite("Edited", source: source), header + "Edited\n")
    }
}
