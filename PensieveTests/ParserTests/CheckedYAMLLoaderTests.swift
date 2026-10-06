import XCTest
import Yams
@testable import Pensieve

final class CheckedYAMLLoaderTests: XCTestCase {
    struct ResourceLimitFixture {
        let name: String
        let yaml: String
        let error: CheckedYAMLLoader.LoaderError
    }

    func testRejectsEveryNonScalarKeyShape() {
        let fixtures = [
            "? [x]\n: y\n",
            "? {a: b}\n: y\n",
            "outer:\n  ? [x]\n  : y\n",
            "items:\n  - ok: true\n  - ? {a: b}\n    : y\n",
            Self.aliasedNonScalarKey(),
            "!!set\n? [x]\n"
        ]

        for yaml in fixtures {
            XCTAssertThrowsError(try CheckedYAMLLoader.load(yaml: yaml), yaml) { error in
                XCTAssertEqual(error as? CheckedYAMLLoader.LoaderError, .nonScalarKey)
            }
        }
    }

    func testScalarAliasRemainsAValidMappingKey() throws {
        let yaml = "anchor: &key anchored\n? *key\n: accepted\n"
        let value = try XCTUnwrap(try CheckedYAMLLoader.load(yaml: yaml) as? [String: Any])
        XCTAssertEqual(value["anchor"] as? String, "anchored")
        XCTAssertEqual(value["anchored"] as? String, "accepted")
    }

    func testSafeCorpusMatchesYamsLoad() throws {
        let yaml = """
        defaults: &defaults
          integer: 42
          float: 3.5
          boolean: true
          nothing: null
          date: 2026-09-26
          binary: !!binary SGVsbG8=
          duration: 1:30
          largest_safe: 59:59:59:59:59:59:59:59:59:59
          int_max: 153722867280912930:7
          negative_int: -153722867280912930:7
          zero_led: !!int 0:0:0:0:0:0:0:0:0:0:0
        alias_value: *defaults
        merged:
          <<: *defaults
          extra: value
        text_star: "use *args"
        text_ampersand: 'A & B'
        text_star_plain: use *args
        text_ampersand_plain: A & B
        nested:
          - one
          - key: [two, three]
        """

        let expected = try XCTUnwrap(try Yams.load(yaml: yaml) as? [String: Any])
        let actual = try XCTUnwrap(try CheckedYAMLLoader.load(yaml: yaml) as? [String: Any])
        XCTAssertEqual(actual as NSDictionary, expected as NSDictionary)
        let expectedDefaults = try XCTUnwrap(expected["defaults"] as? [String: Any])
        let actualDefaults = try XCTUnwrap(actual["defaults"] as? [String: Any])
        XCTAssertEqual(expectedDefaults["int_max"] as? Int, Int.max)
        XCTAssertEqual(actualDefaults["int_max"] as? Int, Int.max)
        XCTAssertEqual(expectedDefaults["negative_int"] as? Int, -Int.max)
        XCTAssertEqual(actualDefaults["negative_int"] as? Int, -Int.max)
    }

    func testMalformedUTF8TagsMatchYamsLoad() throws {
        for yaml in ["name: !<%C0%80> x\n", "name: !<%ED%A0%80> x\n"] {
            let expected = try XCTUnwrap(try Yams.load(yaml: yaml) as? [String: Any])
            let actual = try XCTUnwrap(try CheckedYAMLLoader.load(yaml: yaml) as? [String: Any])
            XCTAssertEqual(actual as NSDictionary, expected as NSDictionary, yaml)
        }
    }

    func testImplicitMergeKeyByteCheckMatchesDefaultResolver() {
        let spellings = [
            "<<", "<<\n", "<<\u{000B}", "<<\u{000C}", "<<\r", "<<\r\n",
            "<<\u{0085}", "<<\u{2028}", "<<\u{2029}",
            "<<\n\n", "<<\r\n\n", "<< ", "<<\t", "<<<", "<", "<<x", "x<<"
        ]

        for spelling in spellings {
            let expected = CheckedYAMLLoader.resolver.resolveTag(of: Node(spelling)) == .merge
            let bytes = Array(spelling.utf8)
            let actual = bytes.withUnsafeBufferPointer {
                CheckedYAMLLoader.matchesImplicitMergeKey($0)
            }
            XCTAssertEqual(actual, expected, spelling.debugDescription)
        }
    }

    func testAliasBombsAndExcessiveDepthAreRefusedQuickly() {
        for fixture in Self.resourceLimitFixtures {
            let start = Date()
            XCTAssertThrowsError(try CheckedYAMLLoader.load(yaml: fixture.yaml), fixture.name) { error in
                XCTAssertEqual(error as? CheckedYAMLLoader.LoaderError, fixture.error)
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 1, fixture.name)
        }

        let scalarAtLimit = String(repeating: "[", count: CheckedYAMLLoader.maximumDepth - 1)
            + "x"
            + String(repeating: "]", count: CheckedYAMLLoader.maximumDepth - 1)
        let scalarPastLimit = "[" + scalarAtLimit + "]"
        let emptyAtLimit = String(repeating: "[", count: CheckedYAMLLoader.maximumDepth)
            + String(repeating: "]", count: CheckedYAMLLoader.maximumDepth)
        let emptyPastLimit = "[" + emptyAtLimit + "]"
        XCTAssertNoThrow(try CheckedYAMLLoader.load(yaml: scalarAtLimit))
        XCTAssertNoThrow(try CheckedYAMLLoader.load(yaml: emptyAtLimit))
        for yaml in [scalarPastLimit, emptyPastLimit] {
            XCTAssertThrowsError(try CheckedYAMLLoader.load(yaml: yaml)) { error in
                XCTAssertEqual(error as? CheckedYAMLLoader.LoaderError, .nestingTooDeep)
            }
        }
    }

    func testAliasFreeDocumentLargerThanExpansionBoundLoads() throws {
        let valueCount = CheckedYAMLLoader.maximumAliasExpansionCost + 1
        let yaml = "values: [" + String(repeating: "value,", count: valueCount) + "]\n"

        let loaded = try XCTUnwrap(try CheckedYAMLLoader.load(yaml: yaml) as? [String: Any])
        let values = try XCTUnwrap(loaded["values"] as? [Any])
        XCTAssertEqual(values.count, valueCount)
    }

    static func overDeepDocument() -> String {
        let containers = CheckedYAMLLoader.maximumDepth - 1
        return "value: " + String(repeating: "[", count: containers)
            + "x"
            + String(repeating: "]", count: containers)
            + "\n"
    }

    func testAliasConstructedDepthIsBoundedOnSmallStack() {
        let hostile = Self.aliasDepthChain(levels: 30, wrappersPerLevel: 62)
        let content = "---\nname: Deep\ndescription: Deep\n\(hostile)---\nBody\n"
        let result = SmallStackProbe()
        let finished = expectation(description: "small-stack parse finished")
        let thread = Thread {
            defer { finished.fulfill() }
            do {
                _ = try CheckedYAMLLoader.load(yaml: hostile)
            } catch {
                result.loaderError = error as? CheckedYAMLLoader.LoaderError
            }
            let parsed = SkillParser.parse(content)
            result.parsedName = parsed.name
            result.parsedBody = parsed.body
        }
        thread.stackSize = 512 * 1_024
        thread.start()
        wait(for: [finished], timeout: TestWait.hostedActionTimeoutSeconds)

        XCTAssertEqual(result.loaderError, .nestingTooDeep)
        XCTAssertNil(result.parsedName)
        XCTAssertEqual(result.parsedBody, content)
        XCTAssertNoThrow(try CheckedYAMLLoader.load(
            yaml: Self.aliasDepthChain(levels: 1, wrappersPerLevel: 62)
        ))
    }

    func testAliasConstructedDepthHonorsTheExactBoundary() throws {
        XCTAssertNoThrow(try CheckedYAMLLoader.load(
            yaml: Self.aliasDepthBoundary(wrappers: 61)
        ))
        XCTAssertThrowsError(try CheckedYAMLLoader.load(
            yaml: Self.aliasDepthBoundary(wrappers: 62)
        )) { error in
            XCTAssertEqual(error as? CheckedYAMLLoader.LoaderError, .nestingTooDeep)
        }
    }

    func testOverflowingSexagesimalIntegersReadAsStrings() throws {
        let hostile = [
            ("description: 1:2:3:4:5:6:7:8:9:10:11\n", "description", "1:2:3:4:5:6:7:8:9:10:11"),
            ("name: 999999999999999999:0\n", "name", "999999999999999999:0"),
            ("a: !!int 1:0:0:0:0:0:0:0:0:0:0:0\n", "a", "1:0:0:0:0:0:0:0:0:0:0:0"),
            ("a: -1:0:0:0:0:0:0:0:0:0:0\n", "a", "-1:0:0:0:0:0:0:0:0:0:0"),
            ("a: 153722867280912930:59\n", "a", "153722867280912930:59"),
            ("a: -153722867280912930:8\n", "a", "-153722867280912930:8"),
            ("a: !!int --153722867280912930:-8\n", "a", "--153722867280912930:-8")
        ]
        for (yaml, key, expected) in hostile {
            let value = try XCTUnwrap(try CheckedYAMLLoader.load(yaml: yaml) as? [String: Any])
            XCTAssertEqual(value[key] as? String, expected, yaml)
        }

        let overflowing = "1:2:3:4:5:6:7:8:9:10:11"
        let frontmatter = "name: Skill\ndescription: \(overflowing)\n"
        let composed = try CheckedYAMLLoader.composeAndLoad(yaml: frontmatter)
        let composedValue = try XCTUnwrap(composed.value as? [String: Any])
        XCTAssertNotNil(composed.root)
        XCTAssertEqual(composedValue["description"] as? String, overflowing)

        let parsed = SkillParser.parse("---\n\(frontmatter)---\nBody\n")
        XCTAssertEqual(parsed.name, "Skill")
        XCTAssertEqual(parsed.description, overflowing)

        XCTAssertNoThrow(try CheckedYAMLLoader.load(
            yaml: "a: \"1:2:3:4:5:6:7:8:9:10:11\"\n"
        ))
        XCTAssertNoThrow(try CheckedYAMLLoader.load(
            yaml: "a: 1:2:3:4:5:6:7:8:9:10:0.5\n"
        ))
    }

    static let resourceLimitFixtures = [
        ResourceLimitFixture(
            name: "alias-built depth",
            yaml: aliasDepthChain(levels: 30, wrappersPerLevel: 62),
            error: .nestingTooDeep
        ),
        ResourceLimitFixture(name: "literal depth", yaml: overDeepDocument(), error: .nestingTooDeep),
        ResourceLimitFixture(
            name: "alias expansion as value",
            yaml: aliasExpansion(levels: 30, finalAsKey: false),
            error: .expandedSizeTooLarge
        ),
        ResourceLimitFixture(
            name: "alias expansion as mapping key",
            yaml: aliasExpansion(levels: 30, finalAsKey: true),
            error: .expandedSizeTooLarge
        )
    ]

    static func aliasExpansion(levels: Int, finalAsKey: Bool = false) -> String {
        var lines = ["a0: &a0 [x, y]"]
        for level in 1...levels {
            lines.append("a\(level): &a\(level) [*a\(level - 1), *a\(level - 1)]")
        }
        lines.append(finalAsKey ? "? *a\(levels)\n: value" : "final: *a\(levels)")
        return lines.joined(separator: "\n") + "\n"
    }

    static let nonScalarKeyFixtures = [
        (name: "direct sequence key", yaml: "? [x]\n: y\n"),
        (name: "aliased sequence key", yaml: aliasedNonScalarKey())
    ]

    static func aliasedNonScalarKey() -> String {
        "key: &key [x]\n? *key\n: value\n"
    }

    static func validDocument(
        _ validYAML: String,
        shadowing explicitKey: String,
        containing hostileYAML: String
    ) -> String {
        let prefix = validYAML.hasSuffix("\n") ? validYAML : validYAML + "\n"
        let nested = hostileYAML.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n")
        return prefix + "<<:\n  \(explicitKey):\n" + nested + "\n"
    }

    static func aliasDepthChain(levels: Int, wrappersPerLevel: Int) -> String {
        var lines = ["a0: &a0 x"]
        for level in 1...levels {
            let open = String(repeating: "[", count: wrappersPerLevel)
            let close = String(repeating: "]", count: wrappersPerLevel)
            lines.append("a\(level): &a\(level) \(open)*a\(level - 1)\(close)")
        }
        lines.append("final: *a\(levels)")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func aliasDepthBoundary(wrappers: Int) -> String {
        let open = String(repeating: "[", count: wrappers)
        let close = String(repeating: "]", count: wrappers)
        return "a: &a \(open)x\(close)\nb: [*a]\n"
    }
}

extension CheckedYAMLLoaderTests {
    func testYamsVersionMatchesCheckedIntegerArithmetic() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projectYAML = try FileService().readFile(at: sourceRoot.appendingPathComponent("project.yml").path)
        let project = try XCTUnwrap(try Yams.load(yaml: projectYAML) as? [String: Any])
        let packages = try XCTUnwrap(project["packages"] as? [String: Any])
        let yams = try XCTUnwrap(packages["Yams"] as? [String: Any])
        XCTAssertEqual(
            yams["exactVersion"] as? String,
            "6.2.2",
            "Before moving Yams, re-read Constructor.swift's base-60 arithmetic and update "
                + "sexagesimalIntegerWouldOverflow"
        )

        let resolvedPath = sourceRoot.appendingPathComponent(
            "Pensieve.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        ).path
        let resolvedData = try FileService().readData(at: resolvedPath)
        let resolved = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: resolvedData) as? [String: Any]
        )
        let pins = try XCTUnwrap(resolved["pins"] as? [[String: Any]])
        let resolvedYams = try XCTUnwrap(pins.first { $0["identity"] as? String == "yams" })
        let resolvedState = try XCTUnwrap(resolvedYams["state"] as? [String: Any])
        XCTAssertEqual(
            resolvedState["version"] as? String,
            "6.2.2",
            "Before moving Yams, re-read Constructor.swift's base-60 arithmetic and update "
                + "sexagesimalIntegerWouldOverflow"
        )
    }

    func testBareScalarInspectionAppliesEveryLoaderGuard() {
        let fixtures = [
            (yaml: "? [x]\n: value\n", error: CheckedYAMLLoader.LoaderError.nonScalarKey),
            (yaml: Self.overDeepDocument(), error: .nestingTooDeep),
            (yaml: Self.aliasExpansion(levels: 30), error: .expandedSizeTooLarge),
            (yaml: "!!merge key: value\n", error: .explicitMergeTag),
            (yaml: "[", error: .invalidYAML)
        ]

        for fixture in fixtures {
            XCTAssertThrowsError(try CheckedYAMLLoader.load(yaml: fixture.yaml)) { error in
                XCTAssertEqual(error as? CheckedYAMLLoader.LoaderError, fixture.error)
            }
            XCTAssertThrowsError(try CheckedYAMLLoader.inspectBareScalar(yaml: fixture.yaml)) { error in
                XCTAssertEqual(error as? CheckedYAMLLoader.LoaderError, fixture.error)
            }
        }
    }
}

private final class SmallStackProbe {
    var loaderError: CheckedYAMLLoader.LoaderError?
    var parsedName: String?
    var parsedBody = ""
}
