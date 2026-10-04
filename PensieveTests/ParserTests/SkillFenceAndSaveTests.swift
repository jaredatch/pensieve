import XCTest
@testable import Pensieve

final class SkillFenceAndSaveTests: XCTestCase {
    func testUnchangedLeadingUnicodeSeparatorsKeepSourceBytes() {
        for scalar in ["\u{85}", "\u{2028}", "\u{2029}"] {
            for ending in ["\n", "\r\n"] {
                let header = "---\(ending)name: A\(ending)description: D\(ending)---\(ending)"
                let source = header + scalar + "Body" + scalar + ending
                XCTAssertEqual(rewrite(SkillParser.stripFrontmatter(source), source: source), source)
            }
        }
    }

    func testRepeatedLeadingUnicodeBodyEditsAddNoUnauthoredBreaks() {
        for scalar in ["\u{85}", "\u{2028}", "\u{2029}"] {
            for ending in ["\n", "\r\n"] {
                let header = "---\(ending)name: A\(ending)description: D\(ending)---\(ending)"
                for suffix in [ending, scalar + ending] {
                    var source = header + scalar + "Body" + suffix
                    for body in ["Body2", "Body3", "Body4"] {
                        source = rewrite(body, source: source)
                        XCTAssertEqual(source, header + scalar + body + suffix)
                        XCTAssertEqual(rewrite(body, source: source), source)
                    }
                }
            }
        }
    }

    func testGeneratedFenceSweepRequiresFirstLineAndColumnZeroClosingFence() {
        for ending in ["\n", "\r\n"] {
            for opening in ["---", "--- ", "---\t", "---\r", " ---", "\n---", "\n\n---"] {
                for closing in ["---", "--- ", "---\t", "---\r", " ---", "\t---"] {
                    for tail in ["\nBody\n", ""] {
                        let source = "\(opening)\nname: A\ndescription: D\n\(closing)\(tail)"
                            .replacingOccurrences(of: "\n", with: ending)
                        let expected = !opening.hasPrefix(" ") && !opening.hasPrefix("\n")
                            && !closing.hasPrefix(" ") && !closing.hasPrefix("\t")
                        let parsed = SkillParser.parse(source)
                        XCTAssertEqual(parsed.hasRequiredFrontmatter, expected, source.debugDescription)
                        XCTAssertEqual(parsed.preservedFile != nil, expected, source.debugDescription)
                        XCTAssertEqual(SkillParser.stripFrontmatter(source), expected ? (tail.isEmpty ? "" : "Body") :
                                        SkillParser.canonicalBody(source), source.debugDescription)
                    }
                }
            }
        }
    }

    func testEmbeddedFenceTextRefusesIdentityRewritesAndKeepsSource() throws {
        for ending in ["\n", "\r\n"] {
            for value in ["description: before---after", "description: '---'", "description: |\n  ---\n  text",
                          "description: D\n# --- comment"] {
                let source = "---\nname: A\n\(value)\nlicense: MIT\n---\nBody\n"
                    .replacingOccurrences(of: "\n", with: ending)
                let parsed = SkillParser.parse(source)
                XCTAssertTrue(parsed.hasRequiredFrontmatter)
                XCTAssertFalse(try XCTUnwrap(parsed.preservedFrontmatter).entriesAreTrustworthy, source.debugDescription)
                XCTAssertNil(SkillSerializer.normalizeIdentity(name: "New", description: "New", parsed: parsed))
                XCTAssertEqual(try XCTUnwrap(parsed.preservedFile).source, source)
            }
        }
    }

    func testUnchangedDraftKeepsMixedAndOddBodyBreaksByteIdentical() {
        for body in ["First\nSecond\r\nThird", "First\rSecond", "First\u{85}Second",
                     "First\u{2028}Second", "First\u{2029}Second"] {
            for header in ["", "---\nname: A\ndescription: D\n---\n\n"] {
                let source = header + body + "\n\n"
                let saved = rewrite(SkillParser.stripFrontmatter(source), source: source)
                XCTAssertEqual(Data(saved.utf8), Data(source.utf8), source.debugDescription)
            }
        }
    }

    func testRepeatedChangedDraftAddsNoLeadingOrTrailingBlankLines() {
        for ending in ["\n", "\r\n"] {
            let header = "---\(ending)name: A\(ending)description: D\(ending)---\(ending)\(ending)"
            var source = header + "Old" + ending
            for _ in 0..<4 {
                source = rewrite("\n\nEdited\n\n", source: source)
                XCTAssertEqual(source, header + "Edited" + ending)
            }
        }
    }

    private func rewrite(_ body: String, source: String) -> String {
        SkillSerializer.rewrite(body: body, preserving: SkillParser.parse(source),
                                fallbackName: "A", fallbackDescription: "D").content
    }
}
