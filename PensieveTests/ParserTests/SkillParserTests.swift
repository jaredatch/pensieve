import XCTest
import Yams
@testable import Pensieve

private struct EmptyFrontmatterFixture {
    let source: String
    let stripped: String
    let changed: String
}

final class SkillParserTests: XCTestCase {
    // MARK: - YAML Frontmatter

    func testParseValidYAMLFrontmatter() {
        let content = """
        ---
        name: TypeScript Best Practices
        description: Enforce TypeScript conventions
        ---

        # TypeScript Best Practices

        Always use strict mode.
        """

        let parsed = SkillParser.parse(content)
        XCTAssertTrue(parsed.hasFrontmatter)
        XCTAssertTrue(parsed.hasRequiredFrontmatter)
        XCTAssertEqual(parsed.name, "TypeScript Best Practices")
        XCTAssertEqual(parsed.description, "Enforce TypeScript conventions")
        XCTAssertTrue(parsed.body.contains("# TypeScript Best Practices"))
        XCTAssertTrue(parsed.body.contains("Always use strict mode."))
    }

    // MARK: - No Frontmatter

    func testParsePlainMarkdown() {
        let content = "# Just Markdown\n\nNo frontmatter here."
        let parsed = SkillParser.parse(content)
        XCTAssertFalse(parsed.hasFrontmatter)
        XCTAssertNil(parsed.name)
        XCTAssertEqual(parsed.body, content)
    }

    // MARK: - Malformed YAML

    func testParseMalformedYAML() {
        let content = """
        ---
        name: [unclosed
        ---

        # Body
        """

        let parsed = SkillParser.parse(content)
        // Yams throws on the unterminated flow sequence -> fall back to whole content as body.
        XCTAssertFalse(parsed.hasFrontmatter)
    }

    func testParseFrontmatterWithoutName() {
        let content = """
        ---
        description: has a description but no name
        ---

        # Body
        """

        let parsed = SkillParser.parse(content)
        // Without a `name`, not recognized as Pensieve frontmatter -> whole content is body.
        XCTAssertFalse(parsed.hasFrontmatter)
    }

    // MARK: - Preserved Frontmatter

    func testPreservesComplexFrontmatterAndIdentifiesEveryTopLevelEntry() throws {
        let frontmatter = """
        # Kept exactly where upstream put it.
        name: Preserved Skill
        description: Keeps upstream YAML
        license: Apache-2.0

        allowed-tools:
          - Read
          - Write
        metadata:
          owner: upstream
          nested:
            enabled: true
        notes: |
          First line.
          Second line.
        tags: [preserved, parser]
        scope: project
        """
        let content = "---\n\(frontmatter)\n---\n\n# Body\nText.\n"

        let parsed = SkillParser.parse(content)
        let preserved = try XCTUnwrap(parsed.preservedFrontmatter)
        XCTAssertEqual(preserved.source, frontmatter)
        XCTAssertTrue(preserved.entriesAreTrustworthy)

        let yaml = try XCTUnwrap(try Yams.load(yaml: frontmatter) as? [String: Any])
        XCTAssertEqual(Set(preserved.entries.map(\.key)), Set(yaml.keys))
        XCTAssertEqual(
            preserved.entries.map { String(preserved.source[$0.sourceRange]) },
            [
                "name: Preserved Skill\n",
                "description: Keeps upstream YAML\n",
                "license: Apache-2.0\n\n",
                "allowed-tools:\n  - Read\n  - Write\n",
                "metadata:\n  owner: upstream\n  nested:\n    enabled: true\n",
                "notes: |\n  First line.\n  Second line.\n",
                "tags: [preserved, parser]\n",
                "scope: project"
            ]
        )
        assertExistingParseFields(
            parsed,
            name: "Preserved Skill",
            description: "Keeps upstream YAML",
            tags: ["preserved", "parser"],
            scope: .project,
            body: "# Body\nText."
        )
    }

    func testUnsafeFrontmatterShapesKeepSourceButRefuseEntryIdentification() throws {
        let fixtures = [
            (
                "{name: Flow, description: Flow description, tags: [flow], scope: user}",
                "Flow",
                "Flow description",
                ["flow"]
            ),
            (
                """
                name: Anchored
                description: Anchor description
                tags: [anchor]
                scope: user
                metadata: &details
                  owner: upstream
                copy: *details
                """,
                "Anchored",
                "Anchor description",
                ["anchor"]
            ),
            (
                "name:\tTabbed\ndescription:\tTab description\ntags:\t[tab]\nscope:\tuser",
                "Tabbed",
                "Tab description",
                ["tab"]
            )
        ]

        for (frontmatter, name, description, tags) in fixtures {
            let parsed = SkillParser.parse("---\n\(frontmatter)\n---\nBody")
            let preserved = try XCTUnwrap(parsed.preservedFrontmatter, "fixture: \(name)")
            XCTAssertEqual(preserved.source, frontmatter, "fixture: \(name)")
            XCTAssertFalse(preserved.entriesAreTrustworthy, "fixture: \(name)")
            assertExistingParseFields(
                parsed,
                name: name,
                description: description,
                tags: tags,
                scope: .user,
                body: "Body"
            )
        }
    }

    func testDottedAnchorAndAliasNamesAreRejectedByGuard() {
        XCTAssertTrue(SkillParser.containsAnchorOrAlias(in: "name: &identity.v1 Anchored"))
        XCTAssertTrue(SkillParser.containsAnchorOrAlias(in: "description: *identity.v1"))
    }

    func testRecordsDistinctTrailingNewlineCountsWithoutChangingBody() {
        let base = "---\nname: Newlines\ndescription: Count them\n---\nBody"
        let fixtures = [(base, 0), (base + "\n", 1), (base + "\n\n\n", 3)]

        for (content, expectedCount) in fixtures {
            let parsed = SkillParser.parse(content)
            XCTAssertEqual(parsed.trailingNewlineCount, expectedCount)
            XCTAssertEqual(parsed.body, "Body")
            XCTAssertEqual(parsed.name, "Newlines")
            XCTAssertEqual(parsed.description, "Count them")
            XCTAssertTrue(parsed.hasFrontmatter)
            XCTAssertTrue(parsed.hasRequiredFrontmatter)
        }
    }

    func testCRLFBodyCanonicalizationMatchesExistingLFContract() {
        let lf = "---\nname: A\ndescription: D\n---\n\nBody\n"
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")

        XCTAssertEqual(SkillParser.stripFrontmatter(lf), "Body")
        XCTAssertEqual(SkillParser.stripFrontmatter(crlf), "Body")
        XCTAssertEqual(SkillParser.canonicalBody("\nBody\n"), "Body")
        XCTAssertEqual(SkillParser.canonicalBody("\r\nBody\r\n"), "Body")
    }

    func testCRLFFrontmatterIdentifiesTheSameEntriesAsLF() throws {
        let lf = "---\nname: A\ndescription: D\nlicense: MIT\n---\n\nBody\n"
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")

        let lfFrontmatter = try XCTUnwrap(SkillParser.parse(lf).preservedFrontmatter)
        let crlfFrontmatter = try XCTUnwrap(SkillParser.parse(crlf).preservedFrontmatter)

        XCTAssertEqual(crlfFrontmatter.entries.map(\.key), lfFrontmatter.entries.map(\.key))
        XCTAssertEqual(crlfFrontmatter.entries.map(\.key), ["name", "description", "license"])
        XCTAssertTrue(crlfFrontmatter.entriesAreTrustworthy)
    }

    func testNonFrontmatterShapesPreserveExistingFallbackBehavior() {
        let bodyOnly = "# Just Markdown\n\nNo frontmatter here.\n"
        let unclosed = "---\nname: Unclosed\ndescription: Still body\n# Body\n"

        for content in [bodyOnly, unclosed] {
            let parsed = SkillParser.parse(content)
            XCTAssertNil(parsed.preservedFrontmatter)
            XCTAssertNil(parsed.name)
            XCTAssertNil(parsed.description)
            XCTAssertTrue(parsed.tags.isEmpty)
            XCTAssertNil(parsed.scope)
            XCTAssertEqual(parsed.body, content)
            XCTAssertFalse(parsed.hasFrontmatter)
            XCTAssertFalse(parsed.hasRequiredFrontmatter)
            XCTAssertEqual(parsed.trailingNewlineCount, 1)
        }
    }

    // MARK: - MDC Parsing (Cursor import) — unchanged contract

    func testParseMDC() {
        let content = """
        ---
        description: TypeScript conventions
        globs: **/*.ts, **/*.tsx
        alwaysApply: false
        ---

        # TypeScript Best Practices

        Always use strict mode.
        """

        let parsed = SkillParser.parseMDC(content)
        XCTAssertEqual(parsed.importedFrom, "cursor")
        XCTAssertNotNil(parsed.cursorConfig)
        XCTAssertEqual(parsed.cursorConfig?.description, "TypeScript conventions")
        XCTAssertEqual(parsed.cursorConfig?.globs, ["**/*.ts", "**/*.tsx"])
        XCTAssertEqual(parsed.cursorConfig?.alwaysApply, false)
        XCTAssertTrue(parsed.body.contains("# TypeScript Best Practices"))
    }

    func testParseMDCAlwaysApplyTrue() {
        let content = """
        ---
        description: Global rule
        alwaysApply: true
        ---

        Apply everywhere.
        """

        let parsed = SkillParser.parseMDC(content)
        XCTAssertEqual(parsed.cursorConfig?.alwaysApply, true)
    }

    private func assertExistingParseFields(
        _ parsed: ParsedSkill,
        name: String,
        description: String,
        tags: [String],
        scope: SkillScope,
        body: String
    ) {
        XCTAssertEqual(parsed.name, name)
        XCTAssertEqual(parsed.description, description)
        XCTAssertEqual(parsed.tags, tags)
        XCTAssertEqual(parsed.scope, scope)
        XCTAssertEqual(parsed.body, body)
        XCTAssertTrue(parsed.hasFrontmatter)
        XCTAssertTrue(parsed.hasRequiredFrontmatter)
    }
}

extension SkillParserTests {
    func testEmptyFrontmatterCrashRegressionPreservesParseStripAndRewriteBehavior() throws {
        let fixtures = [
            EmptyFrontmatterFixture(
                source: "---\n---\nbody\n", stripped: "body", changed: "---\n---\nChanged\n"
            ),
            EmptyFrontmatterFixture(
                source: "---\r\n---\r\nbody\r\n", stripped: "body", changed: "---\r\n---\r\nChanged\r\n"
            ),
            EmptyFrontmatterFixture(source: "---\n---", stripped: "", changed: "---\n---\nChanged"),
            EmptyFrontmatterFixture(
                source: "\n---\n---\n", stripped: "---\n---",
                changed: "---\nname: Fallback\ndescription: Fallback description\n---\n\nChanged\n"
            ),
            EmptyFrontmatterFixture(
                source: "--- \t\r\n--- \t\r", stripped: "", changed: "--- \t\r\n--- \t\r\nChanged"
            )
        ]

        for fixture in fixtures {
            let parsed = SkillParser.parse(fixture.source)
            if fixture.source.hasPrefix("\n") {
                assertBodyOnlyEmptyFrontmatterFixture(fixture, parsed: parsed)
                continue
            }
            let preservedFile = try XCTUnwrap(parsed.preservedFile)

            XCTAssertNil(parsed.name, fixture.source.debugDescription)
            XCTAssertNil(parsed.description, fixture.source.debugDescription)
            XCTAssertFalse(parsed.hasFrontmatter, fixture.source.debugDescription)
            XCTAssertFalse(parsed.hasRequiredFrontmatter, fixture.source.debugDescription)
            XCTAssertTrue(parsed.tags.isEmpty, fixture.source.debugDescription)
            XCTAssertNil(parsed.scope, fixture.source.debugDescription)
            XCTAssertEqual(parsed.body, fixture.source, fixture.source.debugDescription)
            XCTAssertEqual(SkillParser.stripFrontmatter(fixture.source), fixture.stripped)
            XCTAssertEqual(
                preservedFile.frontmatterPrefix + preservedFile.frontmatterSuffix,
                fixture.source
            )

            let unchanged = rewrite(fixture.stripped, preserving: parsed)
            XCTAssertEqual(unchanged, fixture.source, fixture.source.debugDescription)
            let changed = rewrite("Changed", preserving: parsed)
            XCTAssertEqual(changed, fixture.changed, fixture.source.debugDescription)
            XCTAssertEqual(SkillParser.stripFrontmatter(changed), "Changed")
        }
    }

    private func assertBodyOnlyEmptyFrontmatterFixture(_ fixture: EmptyFrontmatterFixture, parsed: ParsedSkill) {
        XCTAssertNil(parsed.name, fixture.source.debugDescription)
        XCTAssertNil(parsed.description, fixture.source.debugDescription)
        XCTAssertFalse(parsed.hasFrontmatter, fixture.source.debugDescription)
        XCTAssertFalse(parsed.hasRequiredFrontmatter, fixture.source.debugDescription)
        XCTAssertTrue(parsed.tags.isEmpty, fixture.source.debugDescription)
        XCTAssertNil(parsed.scope, fixture.source.debugDescription)
        XCTAssertNil(parsed.preservedFrontmatter)
        XCTAssertNil(parsed.preservedFile)
        XCTAssertEqual(parsed.body, fixture.source, fixture.source.debugDescription)
        XCTAssertEqual(SkillParser.stripFrontmatter(fixture.source), fixture.stripped)
        let unchanged = rewrite(fixture.stripped, preserving: parsed)
        XCTAssertEqual(unchanged, fixture.source, fixture.source.debugDescription)
        let changed = rewrite("Changed", preserving: parsed)
        XCTAssertEqual(changed, fixture.changed, fixture.source.debugDescription)
        XCTAssertEqual(SkillParser.stripFrontmatter(changed), "Changed")
    }

    private func rewrite(_ body: String, preserving parsed: ParsedSkill) -> String {
        SkillSerializer.rewrite(
            body: body,
            preserving: parsed,
            fallbackName: "Fallback",
            fallbackDescription: "Fallback description"
        ).content
    }
}
