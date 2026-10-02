import XCTest
@testable import Pensieve

final class SkillFrontmatterTests: XCTestCase {
    // MARK: - Parse (Yams)

    func testParseNameAndDescription() {
        let content = """
        ---
        name: My Skill
        description: What this skill does and when to use it.
        ---

        # My Skill
        Body here.
        """
        let parsed = SkillParser.parse(content)
        XCTAssertTrue(parsed.hasFrontmatter)
        XCTAssertTrue(parsed.hasRequiredFrontmatter)
        XCTAssertEqual(parsed.name, "My Skill")
        XCTAssertEqual(parsed.description, "What this skill does and when to use it.")
        XCTAssertTrue(parsed.body.contains("# My Skill"))
        XCTAssertTrue(parsed.body.contains("Body here."))
    }

    // MARK: - Required-frontmatter predicate (strict; distinct from the tolerant parse)

    func testHasRequiredFrontmatterTrueOnlyWhenBothPresent() {
        let both = SkillParser.parse("""
        ---
        name: A
        description: B
        ---
        body
        """)
        XCTAssertTrue(both.hasRequiredFrontmatter)

        let nameOnly = SkillParser.parse("""
        ---
        name: A
        ---
        body
        """)
        XCTAssertTrue(nameOnly.hasFrontmatter)            // tolerant: a mapping with a name
        XCTAssertFalse(nameOnly.hasRequiredFrontmatter)   // strict: description missing

        let emptyDescription = SkillParser.parse("""
        ---
        name: A
        description: ""
        ---
        body
        """)
        XCTAssertTrue(emptyDescription.hasFrontmatter)
        XCTAssertFalse(emptyDescription.hasRequiredFrontmatter) // empty description fails the gate
    }

    // MARK: - No-frontmatter fallback (a body-only file is NOT a valid skill)

    func testBodyOnlyFallsBackToWholeContentAsBody() {
        let content = "# Just a body\n\nNo frontmatter here."
        let parsed = SkillParser.parse(content)
        XCTAssertFalse(parsed.hasFrontmatter)
        XCTAssertFalse(parsed.hasRequiredFrontmatter)
        XCTAssertNil(parsed.name)
        XCTAssertEqual(parsed.body, content)
    }

    // MARK: - stripFrontmatter (editor read path) on a YAML fence

    func testStripFrontmatterRemovesYAMLFence() {
        let content = """
        ---
        name: A
        description: B
        ---

        # Heading
        Para.
        """
        let body = SkillParser.stripFrontmatter(content)
        XCTAssertFalse(body.contains("name:"))
        XCTAssertFalse(body.hasPrefix("---"))
        XCTAssertTrue(body.contains("# Heading"))
    }

    // MARK: - Fence detection is robust to a `---` line inside the body

    func testFenceDetectionRobustToRuleInBody() {
        let content = """
        ---
        name: A
        description: B
        ---

        Intro paragraph.

        ---

        After a horizontal rule.
        """
        let parsed = SkillParser.parse(content)
        XCTAssertEqual(parsed.name, "A")
        XCTAssertEqual(parsed.description, "B")
        XCTAssertTrue(parsed.body.contains("After a horizontal rule."))
        XCTAssertTrue(parsed.body.contains("---")) // the body keeps its own rule
    }

    // MARK: - Serializer canonical output

    func testSerializeCanonicalOutput() {
        let out = SkillSerializer.serialize(name: "my-skill", description: "Does a thing.", body: "# Body")
        XCTAssertTrue(out.hasPrefix("---\n"))
        XCTAssertTrue(out.contains("name: my-skill"))
        XCTAssertTrue(out.contains("description: Does a thing."))
        XCTAssertFalse(out.contains("version"))
        XCTAssertTrue(out.contains("# Body"))
    }

    // MARK: - Round-trip through Yams (via SkillParser) of awkward values

    func testSerializeRoundTripsAwkwardValues() {
        let awkward: [(name: String, description: String)] = [
            ("colon: in name", "desc with: a colon"),
            ("quote \"here\"", "say \"hi\""),
            ("!important", "no"),       // leading `!`, and the Norway-problem bareword `no`
            ("normal name", "yes"),
            ("123", "456"),             // numeric-looking strings must stay strings
            ("- leading dash", "ok"),
            // Full YAML 1.1 implicit-scalar set Yams' resolver coerces away from String
            // (PLAN-07 / 07.1 review): a timestamp, hex/octal, underscore-grouped int, and
            // the float specials. Each must stay a String across serialize -> Yams.load.
            ("2026-06-30", "2026-06-30"),   // .timestamp -> Date if unquoted
            ("0x3A", "0o7"),                // hex / octal ints
            ("1_000", "012"),               // underscore-grouped / leading-zero ints
            (".nan", ".inf")                // float specials
        ]
        for pair in awkward {
            let serialized = SkillSerializer.serialize(name: pair.name, description: pair.description, body: "# B")
            let parsed = SkillParser.parse(serialized)
            XCTAssertEqual(parsed.name, pair.name, "name round-trip failed for \(pair.name)")
            XCTAssertEqual(parsed.description, pair.description, "description round-trip failed for \(pair.description)")
        }
    }

    // MARK: - The Norway problem specifically

    func testSerializeQuotesNorwayProblemValue() {
        // A bare `no` would be read by Yams as Bool(false); the writer must quote it so the
        // round-trip (through SkillParser, which uses Yams) preserves the string "no".
        let serialized = SkillSerializer.serialize(name: "n", description: "no", body: "b")
        XCTAssertTrue(serialized.contains("\"no\""), "description 'no' must be quoted in canonical output")
        let parsed = SkillParser.parse(serialized)
        XCTAssertEqual(parsed.description, "no")
    }

    // MARK: - Timestamp-like value (the YAML implicit-scalar headline case)

    func testSerializeQuotesTimestampLikeValue() {
        // A bare ISO date is read by Yams as a Date (.timestamp); the writer must quote it so a
        // date-valued name/description survives the round-trip as a String and stays a valid,
        // rebuild-admissible skill. (PLAN-07 / 07.1 review fix.)
        let serialized = SkillSerializer.serialize(name: "Release Notes", description: "2026-06-30", body: "# B")
        XCTAssertTrue(serialized.contains("\"2026-06-30\""), "a timestamp-like description must be quoted")
        let parsed = SkillParser.parse(serialized)
        XCTAssertEqual(parsed.description, "2026-06-30")
        XCTAssertTrue(parsed.hasRequiredFrontmatter)
    }
}
