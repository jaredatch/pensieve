import XCTest
@testable import Pensieve

final class SkillSerializerTests: XCTestCase {
    func testSerializeBasic() {
        let skill = Skill(
            name: "Test Skill",
            skillDescription: "A test skill",
            tags: ["test", "example"],
            scope: .user,
            directoryName: "test-skill"
        )

        let output = SkillSerializer.serialize(skill: skill, body: "# Hello World")
        XCTAssertTrue(output.hasPrefix("---\n"))
        XCTAssertTrue(output.contains("name: Test Skill"))
        XCTAssertTrue(output.contains("description: A test skill"))
        XCTAssertFalse(output.contains("version"))
        XCTAssertFalse(output.contains("format_version"))
        XCTAssertFalse(output.contains("[adapters"))
        XCTAssertTrue(output.contains("# Hello World"))
    }

    func testSerializeQuotesAwkwardValues() {
        let skill = Skill(
            name: "Edge: Case",
            skillDescription: "no",
            directoryName: "edge"
        )

        let output = SkillSerializer.serialize(skill: skill, body: "body")
        // A colon-bearing name and the Norway-problem `no` must be quoted.
        XCTAssertTrue(output.contains("name: \"Edge: Case\""))
        XCTAssertTrue(output.contains("description: \"no\""))
    }

    func testRoundTripThroughParser() {
        let skill = Skill(
            name: "Round Trip Test",
            skillDescription: "Testing round-trip parsing",
            tags: ["test"],
            scope: .project,
            directoryName: "round-trip-test"
        )
        let originalBody = "# Round Trip\n\nThis should survive serialization and parsing."

        let serialized = SkillSerializer.serialize(skill: skill, body: originalBody)
        let parsed = SkillParser.parse(serialized)

        XCTAssertTrue(parsed.hasRequiredFrontmatter)
        XCTAssertEqual(parsed.name, "Round Trip Test")
        XCTAssertEqual(parsed.description, "Testing round-trip parsing")
        XCTAssertTrue(parsed.body.contains("# Round Trip"))
        XCTAssertTrue(parsed.body.contains("This should survive serialization and parsing."))
    }

    func testRewritePreservesComplexFrontmatterAndEveryTerminalLFCount() throws {
        let frontmatter = """
        # upstream comment
        name: Upstream
        description: Original
        license: Apache-2.0
        allowed-tools:
          - Read
          - Write
        metadata:
          owner: upstream
        """
        for suffix in ["", "\n", "\n\n\n"] {
            let original = "---\n\(frontmatter)\n---\n\nOld body\(suffix)"
            let parsed = SkillParser.parse(original)
            let rewritten = SkillSerializer.rewrite(
                body: "Edited body",
                preserving: parsed,
                fallbackName: "Ignored",
                fallbackDescription: "Ignored"
            )

            XCTAssertEqual(rewritten, "---\n\(frontmatter)\n---\n\nEdited body\(suffix)")
            XCTAssertEqual(SkillParser.parse(rewritten).preservedFrontmatter?.source,
                           parsed.preservedFrontmatter?.source)
        }
    }

    func testRewriteKeepsCRLFStructureAndTerminalBreak() {
        let original = "---\r\nname: Upstream\r\ndescription: Original\r\nlicense: MIT\r\n---\r\n\r\nOld\r\n"
        let parsed = SkillParser.parse(original)

        let rewritten = SkillSerializer.rewrite(
            body: "Edited\nSecond",
            preserving: parsed,
            fallbackName: "Ignored",
            fallbackDescription: "Ignored"
        )

        XCTAssertEqual(
            rewritten,
            "---\r\nname: Upstream\r\ndescription: Original\r\nlicense: MIT\r\n---\r\n\r\nEdited\r\nSecond\r\n"
        )
        XCTAssertEqual(SkillParser.parse(rewritten).trailingLineBreaks, "\r\n")
    }

    func testChangedBodyRewriteKeepsEmptyBodyFilesValid() {
        let frontmatter = "---\nname: A\ndescription: D\n---"
        let fixtures = [
            (frontmatter, frontmatter + "\nChanged"),
            (frontmatter + "\n", frontmatter + "\nChanged\n"),
            (frontmatter + "\n\n", frontmatter + "\n\nChanged\n")
        ]

        for (original, expected) in fixtures {
            let rewritten = SkillSerializer.rewrite(
                body: "Changed",
                preserving: SkillParser.parse(original),
                fallbackName: "Ignored",
                fallbackDescription: "Ignored"
            )
            let reparsed = SkillParser.parse(rewritten)

            XCTAssertEqual(rewritten, expected, "original: \(original.debugDescription)")
            XCTAssertEqual(reparsed.name, "A")
            XCTAssertEqual(reparsed.description, "D")
            XCTAssertEqual(reparsed.body, "Changed")
            XCTAssertTrue(reparsed.hasRequiredFrontmatter)
        }
    }

    func testRewritePreservesUntrustworthyFrontmatterAndCanonicalizesBodyOnlyFile() {
        let flow = "---\n{name: Flow, description: Keep, license: MIT}\n---\nOld"
        let flowRewrite = SkillSerializer.rewrite(
            body: "Edited",
            preserving: SkillParser.parse(flow),
            fallbackName: "Ignored",
            fallbackDescription: "Ignored"
        )
        XCTAssertEqual(flowRewrite, "---\n{name: Flow, description: Keep, license: MIT}\n---\nEdited")

        let bodyOnly = SkillParser.parse("Old body\n")
        let canonical = SkillSerializer.rewrite(
            body: "Edited",
            preserving: bodyOnly,
            fallbackName: "Legacy",
            fallbackDescription: "Legacy description"
        )
        XCTAssertEqual(
            canonical,
            SkillSerializer.serialize(name: "Legacy", description: "Legacy description", body: "Edited") + "\n"
        )
    }

    func testNormalizeIdentitySplicesOnlyIdentityEntriesAndIsFixedPoint() throws {
        let fixtures = [
            "\n--- \nname: Old\ndescription: Old\nlicense: MIT\n--- \nBody\n\n",
            "---\nname: Old\ndescription: Old\n---\n\n"
        ]

        for original in fixtures {
            let isBodyOnly = original.hasPrefix("\n")
            if isBodyOnly {
                XCTAssertNil(SkillParser.parse(original).preservedFrontmatter)
                XCTAssertEqual(SkillParser.parse(original).body, original)
            }
            let expected = isBodyOnly
                ? SkillSerializer.serialize(name: "New", description: "New description", body: original)
                : original
                .replacingOccurrences(of: "name: Old", with: "name: New")
                .replacingOccurrences(of: "description: Old", with: "description: New description")
            let first = try XCTUnwrap(SkillSerializer.normalizeIdentity(
                name: "New",
                description: "New description",
                parsed: SkillParser.parse(original)
            ))
            let second = try XCTUnwrap(SkillSerializer.normalizeIdentity(
                name: "New",
                description: "New description",
                parsed: SkillParser.parse(first)
            ))

            XCTAssertEqual(first, expected, original.debugDescription)
            XCTAssertEqual(second, expected, original.debugDescription)
        }
    }

    func testRewritePreservesClosedButInadmissibleFrontmatter() {
        let fixtures = [
            "---\ntitle: T\nlicense: MIT\n---\n\nOld\n",
            "---\nname: A\ndescription: Use: this\nlicense: MIT\n---\n\nOld\n"
        ]

        for original in fixtures {
            let rewritten = SkillSerializer.rewrite(
                body: "Edited",
                preserving: SkillParser.parse(original),
                fallbackName: "Fallback",
                fallbackDescription: "Fallback description"
            )

            XCTAssertEqual(rewritten, original.replacingOccurrences(of: "Old", with: "Edited"))
            XCTAssertTrue(rewritten.contains("license: MIT"))
        }
    }

    func testEmptyBodyRewriteCarriesTerminalLineBreakState() {
        let frontmatter = "---\nname: A\ndescription: D\n---"
        let fixtures = [
            (frontmatter, frontmatter + "\nChanged"),
            (frontmatter + "\n", frontmatter + "\nChanged\n"),
            (frontmatter + "\n\n", frontmatter + "\n\nChanged\n")
        ]

        for (original, expected) in fixtures {
            let first = SkillSerializer.rewrite(
                body: "Changed",
                preserving: SkillParser.parse(original),
                fallbackName: "Ignored",
                fallbackDescription: "Ignored"
            )
            let second = SkillSerializer.rewrite(
                body: "Changed",
                preserving: SkillParser.parse(first),
                fallbackName: "Ignored",
                fallbackDescription: "Ignored"
            )

            XCTAssertEqual(first, expected, original.debugDescription)
            XCTAssertEqual(second, expected, original.debugDescription)
        }
    }

    func testLoneCRClosingFenceRemainsFrontmatterAfterRewrite() {
        let original = "---\nname: A\ndescription: D\n---\r"
        let rewritten = SkillSerializer.rewrite(
            body: "Body",
            preserving: SkillParser.parse(original),
            fallbackName: "Ignored",
            fallbackDescription: "Ignored"
        )
        let reparsed = SkillParser.parse(rewritten)

        XCTAssertEqual(rewritten, "---\nname: A\ndescription: D\n---\r\nBody")
        XCTAssertEqual(reparsed.name, "A")
        XCTAssertEqual(reparsed.description, "D")
        XCTAssertEqual(reparsed.body, "Body")
        XCTAssertTrue(reparsed.hasRequiredFrontmatter)
    }

    func testBodyOnlyCRLFRewriteUsesCRLFForCanonicalFrontmatter() {
        let parsed = SkillParser.parse("Old\r\nBody\r\n")
        let rewritten = SkillSerializer.rewrite(
            body: "Edited\nBody",
            preserving: parsed,
            fallbackName: "Legacy",
            fallbackDescription: "Legacy description"
        )

        XCTAssertEqual(
            rewritten,
            "---\r\nname: Legacy\r\ndescription: Legacy description\r\n---\r\n\r\nEdited\r\nBody\r\n"
        )
    }
}

extension SkillSerializerTests {
    func testDeterministicFrontmatterBoundaryEnumerationIsSafeAndFixedPoint() {
        for blankOnly in ["\n", "\n\n", "\r", "\r\r"] {
            XCTAssertEqual(SkillParser.parse(blankOnly).body, blankOnly)
            XCTAssertEqual(SkillParser.stripFrontmatter(blankOnly), "")
        }

        let endings = ["\n", "\r\n", "\r"]
        let fenceSuffixes = ["", " \t"]
        let frontmatters = [
            "",
            "name: A\ndescription: D",
            "{name: Flow, description: D}",
            "name: [unclosed"
        ]
        var count = 0
        for leadingBlankLines in [0, 2] {
            for fenceSuffix in fenceSuffixes {
                for lineEnding in endings {
                    for frontmatter in frontmatters {
                        // -1: nothing after the closing fence, so an empty-body file ends on the fence itself.
                        for separatorBlankLines in -1...2 {
                            for body in ["", "Body"] where separatorBlankLines >= 0 || body.isEmpty {
                                let terminals = ["", lineEnding, lineEnding + lineEnding, "\r"]
                                for terminal in terminals {
                                    count += 1
                                    let source = enumerationSource(
                                        leadingAndFence: (leadingBlankLines, fenceSuffix),
                                        lineEnding: lineEnding,
                                        frontmatter: frontmatter,
                                        separatorBlankLines: separatorBlankLines,
                                        body: body,
                                        terminal: terminal
                                    )
                                    assertEnumerationCase(source, label: "case \(count)")
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(count, 1_344)
    }

    private func enumerationSource(
        leadingAndFence: (blankLines: Int, fenceSuffix: String),
        lineEnding: String,
        frontmatter: String,
        separatorBlankLines: Int,
        body: String,
        terminal: String
    ) -> String {
        let fence = "---" + leadingAndFence.fenceSuffix
        let leading = String(repeating: lineEnding, count: leadingAndFence.blankLines)
        let yaml = frontmatter.replacingOccurrences(of: "\n", with: lineEnding)
        let beforeClose = yaml.isEmpty ? "" : yaml + lineEnding
        let separator = separatorBlankLines < 0 ? "" : String(repeating: lineEnding, count: separatorBlankLines + 1)
        return leading + fence + lineEnding + beforeClose + fence + separator + body + terminal
    }

    private func assertEnumerationCase(_ source: String, label: String) {
        let parsed = SkillParser.parse(source)
        let editorBody = SkillParser.stripFrontmatter(source)
        if let file = parsed.preservedFile {
            XCTAssertEqual(rewrite(editorBody, preserving: parsed), source, label)
            assertFrontmatterSlices(file, source: source, label: label)
        }

        let changed = rewrite("Changed body", preserving: parsed)
        let reparsed = SkillParser.parse(changed)
        if parsed.name != nil {
            XCTAssertEqual(reparsed.name, parsed.name, label)
            XCTAssertEqual(reparsed.description, parsed.description, label)
        }
        XCTAssertEqual(SkillParser.stripFrontmatter(changed), "Changed body", label)
        XCTAssertEqual(rewrite("Changed body", preserving: reparsed), changed, label)
    }

    private func assertFrontmatterSlices(_ file: PreservedSkillFile, source: String, label: String) {
        let prefixCount = file.frontmatterPrefix.utf8.count
        let suffixCount = file.frontmatterSuffix.utf8.count
        XCTAssertLessThanOrEqual(prefixCount + suffixCount, source.utf8.count, label)
        guard prefixCount + suffixCount <= source.utf8.count else { return }
        let bytes = Array(source.utf8)
        guard let frontmatter = String(
            bytes: bytes[prefixCount..<(bytes.count - suffixCount)],
            encoding: .utf8
        ) else {
            XCTFail("invalid UTF-8, \(label)")
            return
        }
        XCTAssertEqual(file.frontmatterPrefix + frontmatter + file.frontmatterSuffix, source, label)
    }

    private func rewrite(_ body: String, preserving parsed: ParsedSkill) -> String {
        SkillSerializer.rewrite(
            body: body,
            preserving: parsed,
            fallbackName: "Fallback",
            fallbackDescription: "Fallback description"
        )
    }
}
