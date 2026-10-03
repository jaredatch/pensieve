import XCTest
import Yams
@testable import Pensieve

extension CheckedYAMLLoaderTests {
    func testAliasExpansionBudgetAccumulatesScalarBytesAcrossAliases() throws {
        let anchor = "anchor-value: &value " + String(repeating: "x", count: 972) + "\n"
        let larger = "anchor-larger: &larger " + String(repeating: "x", count: 973) + "\n"

        XCTAssertNoThrow(try CheckedYAMLLoader.load(
            yaml: anchor + Self.aliasCopies(name: "value", count: 100)
        ))
        XCTAssertThrowsError(try CheckedYAMLLoader.load(
            yaml: anchor + larger + Self.mixedAliasCopies(primary: "value", secondary: "larger")
        )) { error in
            XCTAssertEqual(error as? CheckedYAMLLoader.LoaderError, .expandedSizeTooLarge)
        }
    }

    func testEmptyTagUsesImplicitScalarChargeAcrossAliases() throws {
        let scalar = String(repeating: "x", count: 972)
        let anchor = "anchor-value: &value !<%00> \(scalar)\n"

        XCTAssertNoThrow(try CheckedYAMLLoader.load(
            yaml: anchor + Self.aliasCopies(name: "value", count: 100)
        ))
        XCTAssertThrowsError(try CheckedYAMLLoader.load(
            yaml: anchor + Self.aliasCopies(name: "value", count: 101)
        )) { error in
            XCTAssertEqual(error as? CheckedYAMLLoader.LoaderError, .expandedSizeTooLarge)
        }
    }

    func testAliasExpansionBudgetAccumulatesTagBytesAcrossAliases() throws {
        let anchor = Self.taggedScalarAnchor(name: "value", expandedCost: 1_000)
        let larger = Self.taggedScalarAnchor(name: "larger", expandedCost: 1_001)

        XCTAssertNoThrow(try CheckedYAMLLoader.load(
            yaml: anchor + Self.aliasCopies(name: "value", count: 100)
        ))
        XCTAssertThrowsError(try CheckedYAMLLoader.load(
            yaml: anchor + larger + Self.mixedAliasCopies(primary: "value", secondary: "larger")
        )) { error in
            XCTAssertEqual(error as? CheckedYAMLLoader.LoaderError, .expandedSizeTooLarge)
        }
    }

    func testExplicitMergeTagIsRefusedOnlyAsAMappingKey() throws {
        let keys = [
            "!!merge key: value\n",
            "anchor: &merge !!merge foo\n? *merge\n: value\n"
        ]
        for yaml in keys {
            XCTAssertThrowsError(try CheckedYAMLLoader.load(yaml: yaml)) { error in
                XCTAssertEqual(error as? CheckedYAMLLoader.LoaderError, .explicitMergeTag)
            }
        }

        let loaded = try XCTUnwrap(
            try CheckedYAMLLoader.load(yaml: "note: !!merge foo\n") as? [String: Any]
        )
        XCTAssertEqual(loaded["note"] as? String, "foo")
    }

    func testAliasExpansionBudgetAccumulatesAcrossAliases() throws {
        let anchor = Self.halfBudgetAnchor()

        XCTAssertNoThrow(try CheckedYAMLLoader.load(yaml: anchor + "copies: [*large]\n"))
        XCTAssertThrowsError(
            try CheckedYAMLLoader.load(yaml: anchor + "copies: [*large, *large, *large]\n")
        ) { error in
            XCTAssertEqual(error as? CheckedYAMLLoader.LoaderError, .expandedSizeTooLarge)
        }
    }

    func testAliasExpansionBudgetHonorsExactBoundary() throws {
        let anchor = Self.halfBudgetAnchor()
        let larger = Self.scalarAnchor(
            name: "larger",
            expandedCost: CheckedYAMLLoader.maximumAliasExpansionCost / 2 + 1
        )

        XCTAssertNoThrow(
            try CheckedYAMLLoader.load(yaml: anchor + "copies: [*large, *large]\n")
        )
        XCTAssertThrowsError(
            try CheckedYAMLLoader.load(
                yaml: anchor + larger + "copies: [*large, *larger]\n"
            )
        ) { error in
            XCTAssertEqual(error as? CheckedYAMLLoader.LoaderError, .expandedSizeTooLarge)
        }
    }

    func testAliasExpansionBudgetChargesEmptyContainersAtTheBoundary() throws {
        let anchors = "sequence: &sequence []\nscalar: &scalar ''\n"
        let exactBoundary = anchors + "copies: ["
            + String(repeating: "*sequence,", count: 4_534)
            + String(repeating: "*scalar,", count: 9)
            + "]\n"

        XCTAssertNoThrow(try CheckedYAMLLoader.load(yaml: exactBoundary))
        XCTAssertThrowsError(try CheckedYAMLLoader.load(
            yaml: exactBoundary + "past-boundary: *sequence\n"
        )) { error in
            XCTAssertEqual(error as? CheckedYAMLLoader.LoaderError, .expandedSizeTooLarge)
        }
    }

    func testImplicitScalarTagChargeMatchesYamsLongestResolvedTag() {
        let resolvedScalarTagNames = Resolver.default.rules.map(\.tag.rawValue)
            + [Tag.Name.str.rawValue]
        let longestResolvedTagByteCount = resolvedScalarTagNames
            .map { $0.utf8.count }
            .max()

        XCTAssertEqual(longestResolvedTagByteCount, 27)
        XCTAssertEqual(
            CheckedYAMLLoader.implicitScalarTagByteCount,
            longestResolvedTagByteCount
        )
    }

    func testTagLengthCapHonorsExactBoundary() throws {
        XCTAssertNoThrow(try CheckedYAMLLoader.load(
            yaml: Self.explicitTagDocument(byteCount: CheckedYAMLLoader.maximumTagByteCount)
        ))
        XCTAssertThrowsError(try CheckedYAMLLoader.load(
            yaml: Self.explicitTagDocument(byteCount: CheckedYAMLLoader.maximumTagByteCount + 1)
        )) { error in
            XCTAssertEqual(error as? CheckedYAMLLoader.LoaderError, .tagTooLong)
        }
    }

    func testOversizedWrittenAndDirectiveTagsAreRefusedQuickly() {
        for fixture in Self.oversizedTagDocuments {
            XCTAssertLessThan(fixture.yaml.utf8.count, 1_000_000, fixture.name)
            let start = Date()
            XCTAssertThrowsError(try CheckedYAMLLoader.load(yaml: fixture.yaml), fixture.name) { error in
                XCTAssertEqual(error as? CheckedYAMLLoader.LoaderError, .tagTooLong)
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 1, fixture.name)
        }
    }

    func testMegabyteSlowConstructionDocumentsAreDecidedQuickly() {
        let mergeDocument = Self.explicitMergeTagDocument()
        XCTAssertEqual(mergeDocument.components(separatedBy: "!!merge").count - 1, 1)
        XCTAssertTrue(mergeDocument.hasSuffix("!!merge final-key: value\n"))
        let fixtures = [
            (
                name: "many explicit merge tags",
                yaml: Self.manyExplicitMergeTagDocument(),
                error: CheckedYAMLLoader.LoaderError.explicitMergeTag
            ),
            (
                name: "explicit merge tags",
                yaml: mergeDocument,
                error: CheckedYAMLLoader.LoaderError.explicitMergeTag
            ),
            (
                name: "aliased long scalar",
                yaml: Self.aliasedLongScalarDocument(),
                error: CheckedYAMLLoader.LoaderError.expandedSizeTooLarge
            ),
            (
                name: "aliased long tag",
                yaml: Self.aliasedLongTagDocument(),
                error: CheckedYAMLLoader.LoaderError.tagTooLong
            ),
            (
                name: "directive tag enlarged by UTF-8 repair",
                yaml: Self.repairedDirectiveTagDocument(),
                error: CheckedYAMLLoader.LoaderError.tagTooLong
            ),
            (
                name: "nested merge mappings",
                yaml: Self.nestedMergeDocument(levels: 62, keyCount: 238_000),
                error: CheckedYAMLLoader.LoaderError.mergeNestingTooDeep
            ),
            (
                name: "aliased nested merge mappings",
                yaml: Self.aliasedNestedMergeDocument(levels: 62),
                error: CheckedYAMLLoader.LoaderError.mergeNestingTooDeep
            )
        ]

        for fixture in fixtures {
            XCTAssertGreaterThan(fixture.yaml.utf8.count, 900_000, fixture.name)
            XCTAssertLessThan(fixture.yaml.utf8.count, 1_000_000, fixture.name)
            let start = ProcessInfo.processInfo.systemUptime
            XCTAssertThrowsError(try CheckedYAMLLoader.load(yaml: fixture.yaml), fixture.name) { error in
                XCTAssertEqual(error as? CheckedYAMLLoader.LoaderError, fixture.error)
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            // The slowest checked fixture takes ~0.5 s on the mini; delayed merge refusal takes >8 s.
            // Five seconds leaves CI headroom while detecting construction before refusal.
            XCTAssertLessThan(elapsed, 5, fixture.name)
        }
    }

    func testMergeNestingHonorsExactBoundaryThroughAliases() throws {
        XCTAssertEqual(CheckedYAMLLoader.maximumMergeNestingDepth, 4)
        XCTAssertNoThrow(try CheckedYAMLLoader.load(
            yaml: Self.nestedMergeDocument(
                levels: CheckedYAMLLoader.maximumMergeNestingDepth,
                keyCount: 1
            )
        ))
        XCTAssertNoThrow(try CheckedYAMLLoader.load(
            yaml: Self.aliasedNestedMergeDocument(
                levels: CheckedYAMLLoader.maximumMergeNestingDepth,
                padded: false
            )
        ))

        for yaml in [
            Self.nestedMergeDocument(
                levels: CheckedYAMLLoader.maximumMergeNestingDepth + 1,
                keyCount: 1
            ),
            Self.aliasedNestedMergeDocument(
                levels: CheckedYAMLLoader.maximumMergeNestingDepth + 1,
                padded: false
            )
        ] {
            XCTAssertThrowsError(try CheckedYAMLLoader.load(yaml: yaml)) { error in
                XCTAssertEqual(error as? CheckedYAMLLoader.LoaderError, .mergeNestingTooDeep)
            }
        }
    }

    func testMergeKeySpellingsHonorExactNestingBoundary() throws {
        for spelling in Self.mergeKeySpellings {
            XCTAssertNoThrow(
                try CheckedYAMLLoader.load(yaml: spelling.document(
                    CheckedYAMLLoader.maximumMergeNestingDepth
                )),
                spelling.name
            )
            XCTAssertThrowsError(try CheckedYAMLLoader.load(yaml: spelling.document(
                CheckedYAMLLoader.maximumMergeNestingDepth + 1
            )), spelling.name) { error in
                XCTAssertEqual(error as? CheckedYAMLLoader.LoaderError, .mergeNestingTooDeep)
            }
        }
    }

    static func explicitMergeTagDocument() -> String {
        let ordinary = (0..<38_000).map { "key-\($0): ordinary-value\n" }.joined()
        return ordinary + "!!merge final-key: value\n"
    }

    static func manyExplicitMergeTagDocument() -> String {
        (0..<38_000).map { "!!merge key-\($0): value\n" }.joined()
    }

    static func aliasedLongScalarDocument() -> String {
        let scalar = String(repeating: "x", count: 950_000)
        let uses = String(repeating: "  - {*long: value}\n", count: 1_000)
        return "anchor: &long \(scalar)\nuses:\n" + uses
    }

    static func aliasedLongTagDocument() -> String {
        let tag = "tag:" + String(repeating: "x", count: 800_000)
        let uses = String(repeating: "*x,", count: 50_000)
        return "a: &x !<\(tag)> \"\"\nb: [\(uses)]\n"
    }

    static func repairedDirectiveTagDocument() -> String {
        let prefix = "tag:" + String(repeating: "%C0%80", count: 125)
        let uses = String(repeating: "!x!a a,", count: 140_000)
        return "%TAG !x! \(prefix)\n---\nb: [\(uses)]\n"
    }

    static func nestedMergeDocument(levels: Int, keyCount: Int) -> String {
        String(repeating: "{<<: ", count: levels)
            + bareFlowMapping(keyCount: keyCount)
            + String(repeating: "}", count: levels)
    }

    static func bareFlowMapping(keyCount: Int) -> String {
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var mapping = "{"
        mapping.reserveCapacity(keyCount * 4 + 2)
        for value in 0..<keyCount {
            mapping.append(digits[(value / (62 * 62)) % 62])
            mapping.append(digits[(value / 62) % 62])
            mapping.append(digits[value % 62])
            mapping.append(",")
        }
        mapping.append("}")
        return mapping
    }

    static func aliasedNestedMergeDocument(levels: Int, padded: Bool = true) -> String {
        var lines = padded ? ["padding: " + String(repeating: "x", count: 940_000)] : []
        lines.append("merge0: &merge0 {}")
        for level in 1...levels {
            lines.append("merge\(level): &merge\(level) {<<: [*merge\(level - 1)]}")
        }
        lines.append("final: *merge\(levels)")
        return lines.joined(separator: "\n") + "\n"
    }

    static let mergeKeySpellings: [(
        name: String,
        document: (Int) -> String
    )] = [
        ("direct alias value", { mergeAliasDocument(levels: $0, key: "<<") }),
        ("anchored key alias", anchoredMergeKeyDocument),
        ("empty tag plain key", { mergeAliasDocument(levels: $0, key: "!<%00> <<") }),
        ("empty tag quoted key", { mergeAliasDocument(levels: $0, key: "!<%00> '<<'") }),
        ("empty tag LF key", { mergeAliasDocument(levels: $0, key: "!<%00> \"<<\\n\"") }),
        ("empty tag CRLF key", { mergeAliasDocument(levels: $0, key: "!<%00> \"<<\\r\\n\"") }),
        ("empty tag CR key", { mergeAliasDocument(levels: $0, key: "!<%00> \"<<\\r\"") }),
        ("empty tag VT key", { mergeAliasDocument(levels: $0, key: "!<%00> \"<<\\v\"") }),
        ("empty tag FF key", { mergeAliasDocument(levels: $0, key: "!<%00> \"<<\\f\"") }),
        ("empty tag NEL key", { mergeAliasDocument(levels: $0, key: "!<%00> \"<<\\N\"") }),
        ("empty tag LS key", { mergeAliasDocument(levels: $0, key: "!<%00> \"<<\\L\"") }),
        ("empty tag PS key", { mergeAliasDocument(levels: $0, key: "!<%00> \"<<\\P\"") }),
        ("empty tag literal key", literalMergeKeyDocument)
    ]

    static var oversizedTagDocuments: [(name: String, yaml: String)] {
        let prefix = "tag:" + String(repeating: "x", count: 500_000)
        let uses = String(repeating: "!x!a a,", count: 60_000)
        return [
            ("tag directive", "%TAG !x! \(prefix)\n---\nschema_version: !x!a 1\nuses: [\(uses)]\n"),
            ("written tag", "schema_version: !<\(prefix)> 1\n"),
            ("written sequence tag", "value: !<\(prefix)> []\n"),
            ("written mapping tag", "value: !<\(prefix)> {}\n"),
            ("directive sequence tag", "%TAG !x! \(prefix)\n---\nvalue: !x!a []\n"),
            ("directive mapping tag", "%TAG !x! \(prefix)\n---\nvalue: !x!a {}\n")
        ]
    }

    private static func halfBudgetAnchor() -> String {
        scalarAnchor(name: "large", expandedCost: CheckedYAMLLoader.maximumAliasExpansionCost / 2)
    }

    private static func scalarAnchor(name: String, expandedCost: Int) -> String {
        let scalarBytes = expandedCost - 1 - CheckedYAMLLoader.implicitScalarTagByteCount
        return "anchor-\(name): &\(name) " + String(repeating: "x", count: scalarBytes) + "\n"
    }

    private static func taggedScalarAnchor(name: String, expandedCost: Int) -> String {
        let tag = "tag:" + String(repeating: "x", count: 196)
        let scalarBytes = expandedCost - 1 - tag.utf8.count
        return "anchor-\(name): &\(name) !<\(tag)> "
            + String(repeating: "x", count: scalarBytes) + "\n"
    }

    private static func explicitTagDocument(byteCount: Int) -> String {
        let tag = "tag:" + String(repeating: "x", count: byteCount - 4)
        return "value: !<\(tag)> scalar\n"
    }

    private static func aliasCopies(name: String, count: Int) -> String {
        "copies: [" + String(repeating: "*\(name),", count: count) + "]\n"
    }

    private static func mixedAliasCopies(primary: String, secondary: String) -> String {
        "copies: [" + String(repeating: "*\(primary),", count: 99) + "*\(secondary),]\n"
    }

    private static func mergeAliasDocument(levels: Int, key: String) -> String {
        var lines = ["merge0: &merge0 {}"]
        for level in 1...levels {
            lines.append("merge\(level): &merge\(level) {\(key): *merge\(level - 1)}")
        }
        lines.append("final: *merge\(levels)")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func anchoredMergeKeyDocument(levels: Int) -> String {
        var lines = ["merge-key: &merge-key <<", "merge0: &merge0 {}"]
        for level in 1...levels {
            lines.append("merge\(level): &merge\(level)\n  ? *merge-key\n  : *merge\(level - 1)")
        }
        lines.append("final: *merge\(levels)")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func literalMergeKeyDocument(levels: Int) -> String {
        var lines = ["merge0: &merge0 {}"]
        for level in 1...levels {
            lines.append("""
                merge\(level): &merge\(level)
                  ? !<%00> |
                    <<
                  : *merge\(level - 1)
                """)
        }
        lines.append("final: *merge\(levels)")
        return lines.joined(separator: "\n") + "\n"
    }
}
