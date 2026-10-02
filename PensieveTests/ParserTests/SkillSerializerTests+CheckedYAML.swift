import XCTest
import Yams
@testable import Pensieve

extension SkillSerializerTests {
    func testGeneratedStringSweepRoundTripsEveryQuotedFieldThroughCheckedLoader() throws {
        let fragments = Self.refusedOneLineValues + Self.stringFallbackOneLineValues + [
            "? [x]",
            "? {a: b}",
            "outer:\n  nested:\n    ? [x]\n    : y",
            "!tag", "*alias", "&anchor", "# comment", "[flow]", "{flow}", "- item", ": value",
            "", "left\u{FFFE}right", "left\u{FFFF}right"
        ]
        let values = Self.decoratedValues(fragments)

        for (index, value) in values.enumerated() {
            let label = "case \(index): \(value.debugDescription)"
            try assertSkillCategoryAndScenarioFields(value, label: label)
            try assertOverlayAndDeployFields(value, label: label)
        }
    }

    func testEveryOneLineCheckedLoaderRefusalIsQuotedAndRoundTrips() throws {
        for value in Self.refusedOneLineValues {
            XCTAssertFalse(SkillSerializer.hasYAMLUnsafeControl(value), value)
            XCTAssertThrowsError(try CheckedYAMLLoader.load(yaml: value), value)

            let written = SkillSerializer.quotedScalar(value)
            XCTAssertTrue(written.hasPrefix("\""), value)
            XCTAssertEqual(try CheckedYAMLLoader.load(yaml: written) as? String, value)
        }

        for value in Self.stringFallbackOneLineValues {
            XCTAssertEqual(try CheckedYAMLLoader.load(yaml: value) as? String, value)
            let written = SkillSerializer.quotedScalar(value)
            XCTAssertTrue(written.hasPrefix("\""), value)
            XCTAssertEqual(try CheckedYAMLLoader.load(yaml: written) as? String, value)
        }
    }

    func testCheckedOraclePreservesTheExistingSerializerCorpusByteForByte() {
        let values = [
            // SkillSerializerTests.
            "Test Skill", "A test skill", "Edge: Case", "no", "Round Trip Test",
            "Testing round-trip parsing", "Legacy", "Legacy description", "New", "New description",
            "Fallback", "Fallback description",
            // SkillFrontmatterTests.
            "my-skill", "Does a thing.", "colon: in name", "desc with: a colon", "quote \"here\"",
            "say \"hi\"", "!important", "normal name", "yes", "123", "456", "- leading dash", "ok",
            "2026-06-30", "0x3A", "0o7", "1_000", "012", ".nan", ".inf", "n", "Release Notes",
            // ManifestServiceTests and ManifestServiceTests+YAMLSafety.
            "Swift", "git:github.com/me/b", "git:github.com/me/a", "swiftui-review", "swift-style",
            "../evil/../name", "plain", "review", "swift", "Swift: rules", "**/*.swift", "claude-code",
            "frac", "github.com/x/y", "remote", "App A", "App B", "marker:/tmp/b", "PDF_Tools",
            "evil-x", "../evil", "skills/pdf", "1970-01-01T00:00:00Z", "1970-01-01T00:00:00.000Z",
            "2023-11-14T22:13:20.000Z", "2023-11-14T22:13:20.123Z",
            "2026-07-30T16:00:00Z", "2026-07-30T16:00:00.000Z",
            "A, {weird} \"name\" with \\ and\ttab\nnewline",
            // ManifestScenarioTests.
            "Backend", "Frontend", "sql", "api", "cursor", "claudeCode", "react", "vite", "codex",
            "a/b", "", "日本語", "unicode", "openClaw", "Same", "a", "b", "one", "two", "x",
            "First", "Last", "Healed", "not-a-uuid",
            "D23BF2CE-86FD-4F89-951D-F16E446F91F2", "A96A4BD5-60FA-4904-AD9A-9452D87501D8",
            "1E3AB3B9-53EF-4051-9215-201177354373", "7CEEEAE8-75B8-4B0C-AC97-79453FE340A7",
            "8573D923-EC84-4325-8CC6-C925A22B14B1", "246805E8-224C-4D5E-874D-1B35BDA9BA6E",
            "8787F07B-40FA-46FD-A9C2-D892D07D4661", "F59F385D-E42D-425F-843C-D9019B7BA8BA",
            "D52AB43B-57E4-496C-AE4D-B14A2D574F4E", "d52ab43b-57e4-496c-ae4d-b14a2d574f4e",
            "0AAAAAAA-1111-4222-8333-444444444444", "0BBBBBBB-1111-4222-8333-444444444444",
            // Manifest deploy-intent serializer tests.
            "future.agent", "github.com/owner/one", "github.com/owner/two", "host:path", "inner space",
            "café/工具", "😀", "e\u{301}", "Exact.Slug", "alpha", "test", "agent.future-2"
        ]

        for value in Set(values) {
            XCTAssertEqual(SkillSerializer.quotedScalar(value), Self.legacyQuotedScalar(value), value)
        }
    }

    func testQuotedScalarLiteralBytesStayPinned() {
        let fixtures = [
            ("colon: in name", "\"colon: in name\""),
            ("desc with: a colon", "\"desc with: a colon\""),
            ("quote \"here\"", "quote \"here\""),
            ("say \"hi\"", "say \"hi\""),
            ("!important", "\"!important\""),
            ("no", "\"no\""),
            ("normal name", "normal name"),
            ("yes", "\"yes\""),
            ("123", "\"123\""),
            ("456", "\"456\""),
            ("- leading dash", "\"- leading dash\""),
            ("ok", "ok"),
            ("2026-06-30", "\"2026-06-30\""),
            ("0x3A", "\"0x3A\""),
            ("0o7", "\"0o7\""),
            ("1_000", "\"1_000\""),
            ("012", "\"012\""),
            (".nan", "\".nan\""),
            (".inf", "\".inf\""),
            ("<<", "<<"),
            ("=", "="),
            ("._", "._"),
            ("0b_", "0b_"),
            ("99999999999999999999999999999999999999", "99999999999999999999999999999999999999"),
            ("0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF", "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"),
            ("tab\tvalue", "\"tab\\tvalue\""),
            ("line\nvalue", "\"line\\nvalue\""),
            ("path\\value: tail", "\"path\\\\value: tail\""),
            ("left\u{80}right", "\"left\\x80right\"")
        ]

        for (value, expected) in fixtures {
            XCTAssertEqual(SkillSerializer.quotedScalar(value), expected, value)
        }
    }

    func testLegacyOracleFreezesThePre38Escaper() {
        XCTAssertEqual(
            Self.legacyQuotedScalar("left\u{FFFE}right"),
            "\"left\u{FFFE}right\""
        )
    }

    func testCheckedLoaderInspectsOneBareScalarForTheWriter() throws {
        let (mergeValue, mergeNeedsQuote) = try CheckedYAMLLoader.inspectBareScalar(yaml: "<<")
        XCTAssertEqual(mergeValue as? String, "<<")
        XCTAssertFalse(mergeNeedsQuote)

        let (nonSpecificValue, nonSpecificNeedsQuote) = try CheckedYAMLLoader.inspectBareScalar(
            yaml: "! value"
        )
        XCTAssertEqual(nonSpecificValue as? String, "value")
        XCTAssertFalse(nonSpecificNeedsQuote)

        let oversizedDecimal = "99999999999999999999999999999999999999"
        let (decimalValue, decimalNeedsQuote) = try CheckedYAMLLoader.inspectBareScalar(
            yaml: oversizedDecimal
        )
        XCTAssertEqual(decimalValue as? String, oversizedDecimal)
        XCTAssertFalse(decimalNeedsQuote)

        let base60 = "1:2:3:4:5:6:7:8:9:10:11"
        let (overflowValue, overflowNeedsQuote) = try CheckedYAMLLoader.inspectBareScalar(yaml: base60)
        XCTAssertEqual(overflowValue as? String, base60)
        XCTAssertTrue(overflowNeedsQuote)
    }

    private func loadMappings(
        _ yaml: String,
        originalValue: String,
        expectedLegacyQuoteCount: Int,
        label: String
    ) throws -> [[String: Any]] {
        let checked = try XCTUnwrap(try CheckedYAMLLoader.load(yaml: yaml) as? [String: Any], label)
        if Self.requiresLegacyQuote(originalValue) {
            let quoted = "\"\(SkillSerializer.escapeForDoubleQuoted(originalValue))\""
            let quoteCount = yaml.components(separatedBy: quoted).count - 1
            XCTAssertEqual(
                quoteCount,
                expectedLegacyQuoteCount,
                "\(label): an older-reader value was not quoted"
            )
            guard quoteCount == expectedLegacyQuoteCount else { return [checked] }
        }
        let legacy = try XCTUnwrap(try Yams.load(yaml: yaml) as? [String: Any], label)
        return [checked, legacy]
    }

    private func assertSkillCategoryAndScenarioFields(_ value: String, label: String) throws {
        let skill = SkillSerializer.serialize(name: value, description: value, body: "Body")
        let frontmatter = try XCTUnwrap(SkillParser.parse(skill).preservedFrontmatter?.source, label)
        for skillMap in try loadMappings(
            frontmatter,
            originalValue: value,
            expectedLegacyQuoteCount: 2,
            label: label
        ) {
            XCTAssertEqual(skillMap["name"] as? String, value, label)
            XCTAssertEqual(skillMap["description"] as? String, value, label)
        }

        let category = ManifestService.serializeCategory(
            CategoryRecord(name: value, projectKeys: [value], skillSlugs: [value])
        )
        for categoryMap in try loadMappings(
            category,
            originalValue: value,
            expectedLegacyQuoteCount: 3,
            label: label
        ) {
            XCTAssertEqual(categoryMap["name"] as? String, value, label)
            XCTAssertEqual((categoryMap["project_keys"] as? [Any])?.first as? String, value, label)
            XCTAssertEqual((categoryMap["skill_slugs"] as? [Any])?.first as? String, value, label)
        }

        let scenario = ManifestService.serializeScenario(
            ScenarioRecord(id: value, name: value, skillSlugs: [value], agents: [value])
        )
        for scenarioMap in try loadMappings(
            scenario,
            originalValue: value,
            expectedLegacyQuoteCount: 4,
            label: label
        ) {
            XCTAssertEqual(scenarioMap["id"] as? String, value, label)
            XCTAssertEqual(scenarioMap["name"] as? String, value, label)
            XCTAssertEqual((scenarioMap["skill_slugs"] as? [Any])?.first as? String, value, label)
            XCTAssertEqual((scenarioMap["agents"] as? [Any])?.first as? String, value, label)
        }
    }

    private func assertOverlayAndDeployFields(_ value: String, label: String) throws {
        let overlay = ManifestService.serializeSkillOverlay(
            SkillOverlay(
                slug: value,
                createdAt: Date(timeIntervalSince1970: 0),
                scope: .user,
                tags: [value],
                cursor: CursorAdapterConfig(description: value, globs: [value], alwaysApply: false),
                agents: [value],
                origin: .imported(from: value)
            )
        )
        for overlayMap in try loadMappings(
            overlay,
            originalValue: value,
            expectedLegacyQuoteCount: 6,
            label: label
        ) {
            XCTAssertEqual(overlayMap["slug"] as? String, value, label)
            XCTAssertEqual((overlayMap["tags"] as? [Any])?.first as? String, value, label)
            XCTAssertEqual((overlayMap["agents"] as? [Any])?.first as? String, value, label)
            let origin = try XCTUnwrap(overlayMap["origin"] as? [String: Any], label)
            XCTAssertEqual(origin["imported_from"] as? String, value, label)
            let cursor = try XCTUnwrap(overlayMap["cursor"] as? [String: Any], label)
            XCTAssertEqual(cursor["description"] as? String, value, label)
            XCTAssertEqual((cursor["globs"] as? [Any])?.first as? String, value, label)
        }

        let deploy = ManifestService.serializeDeployIntent(slug: value, platforms: [value])
        for deployMap in try loadMappings(
            deploy,
            originalValue: value,
            expectedLegacyQuoteCount: 2,
            label: label
        ) {
            XCTAssertEqual(deployMap["slug"] as? String, value, label)
            XCTAssertEqual((deployMap["platforms"] as? [Any])?.first as? String, value, label)
        }
    }

    private static var refusedOneLineValues: [String] {
        [
            flowAliasExpansion(levels: 17),
            String(repeating: "[", count: 64) + "x" + String(repeating: "]", count: 64),
            flowAliasDepth(levels: 64)
        ]
    }

    private static var stringFallbackOneLineValues: [String] {
        [
            "1:2:3:4:5:6:7:8:9:10:11",
            "-1:0:0:0:0:0:0:0:0:0:0"
        ]
    }

    private static func requiresLegacyQuote(_ value: String) -> Bool {
        let yamlWhitespace = CharacterSet(charactersIn: " \t\r\n\u{85}\u{2028}\u{2029}")
        return stringFallbackOneLineValues.contains(
            value.trimmingCharacters(in: yamlWhitespace)
        )
    }

    private static func decoratedValues(_ fragments: [String]) -> [String] {
        let whitespace = [("", ""), (" ", ""), ("", " "), (" ", " "),
                          ("\t", ""), ("", "\t"), ("\t", "\t")]
        let lineBreaks = [("", ""), ("line\n", "\nline"), ("line\r\n", "\r\nline"),
                          ("line\r", "\rline"), ("line\u{85}", "\u{85}line"),
                          ("line\u{2028}", "\u{2028}line"), ("line\u{2029}", "\u{2029}line")]
        let nonASCII = [("", ""), ("日本語 ", " café 👩🏽‍💻")]
        return fragments.flatMap { fragment in
            whitespace.flatMap { leading, trailing in
                lineBreaks.flatMap { linePrefix, lineSuffix in
                    nonASCII.map { unicodePrefix, unicodeSuffix in
                        leading + linePrefix + unicodePrefix + fragment + unicodeSuffix + lineSuffix + trailing
                    }
                }
            }
        }
    }

    private static func flowAliasExpansion(levels: Int) -> String {
        var values = ["&a0 [x, x]"]
        for level in 1...levels {
            values.append("&a\(level) [*a\(level - 1), *a\(level - 1)]")
        }
        values.append("*a\(levels)")
        return "[" + values.joined(separator: ", ") + "]"
    }

    private static func flowAliasDepth(levels: Int) -> String {
        var values = ["&d0 [x]"]
        for level in 1...levels {
            values.append("&d\(level) [*d\(level - 1)]")
        }
        values.append("*d\(levels)")
        return "[" + values.joined(separator: ", ") + "]"
    }

    private static func legacyQuotedScalar(_ value: String) -> String {
        guard ((try? Yams.load(yaml: value)) as? String != value)
                || legacyHasYAMLUnsafeControl(value) else { return value }
        return "\"\(legacyEscapeForDoubleQuoted(value))\""
    }

    private static func legacyHasYAMLUnsafeControl(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            $0.value < 0x20 || ($0.value >= 0x7F && $0.value <= 0x9F)
                || $0.value == 0x2028 || $0.value == 0x2029
        }
    }

    private static func legacyEscapeForDoubleQuoted(_ value: String) -> String {
        var output = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": output += "\\\\"
            case "\"": output += "\\\""
            case "\n": output += "\\n"
            case "\t": output += "\\t"
            case "\r": output += "\\r"
            case "\u{0}": output += "\\0"
            default:
                let scalarValue = scalar.value
                if scalarValue < 0x20 || (scalarValue >= 0x7F && scalarValue <= 0x9F) {
                    output += String(format: "\\x%02X", scalarValue)
                } else if scalarValue == 0x2028 || scalarValue == 0x2029 {
                    output += String(format: "\\u%04X", scalarValue)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output
    }

}
