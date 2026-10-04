import Darwin
import XCTest
@testable import Pensieve

extension SkillParserTests {
    func testNonScalarKeysAndAliasBombFallBackToWholeContent() {
        let hostileFrontmatter = [
            "? [x]\n: y",
            "name: Skill\ndescription: Description\nmeta:\n  ? [x]\n  : y",
            "name: Skill\ndescription: Description\nitems:\n  - ? {a: b}\n    : y",
            "name: Skill\ndescription: Description\n" + CheckedYAMLLoaderTests.aliasedNonScalarKey(),
            "name: Skill\ndescription: Description\nbad: !!set\n  ? [x]"
        ] + [
            CheckedYAMLLoaderTests.aliasExpansion(levels: 30)
        ]
        let lineEndings = ["\n", "\r\n"]
        let terminalCounts = [0, 1, 3]

        for frontmatter in hostileFrontmatter {
            for lineEnding in lineEndings {
                for terminalCount in terminalCounts {
                    let lfContent = "---\n\(frontmatter)\n---\nBody\n---\nRule"
                        + String(repeating: "\n", count: terminalCount)
                    let content = lfContent.replacingOccurrences(of: "\n", with: lineEnding)
                    let start = Self.threadCPUTime()
                    let parsed = SkillParser.parse(content)
                    XCTAssertLessThan(Self.threadCPUTime() - start, 1, frontmatter)
                    XCTAssertNil(parsed.name, frontmatter)
                    XCTAssertEqual(parsed.body, content, frontmatter)
                }
            }
        }
    }

    func testGeneratedFrontmatterSweepPreservesAcceptedSourceAndFallbacks() throws {
        let acceptedFrontmatter = """
        name: Sweep
        description: "Use *args & values"
        metadata: &metadata
          owner: upstream
        copy: *metadata
        """
        let lineEndings = ["\n", "\r\n"]
        let terminalCounts = [0, 1, 3]

        for lineEnding in lineEndings {
            for terminalCount in terminalCounts {
                let lfSource = "---\n\(acceptedFrontmatter)\n---\nBody\n---\nRule"
                    + String(repeating: "\n", count: terminalCount)
                let source = lfSource.replacingOccurrences(of: "\n", with: lineEnding)
                let parsed = SkillParser.parse(source)
                XCTAssertEqual(parsed.name, "Sweep")
                XCTAssertEqual(parsed.body, ["Body", "---", "Rule"].joined(separator: lineEnding))

                let rewritten = SkillSerializer.rewrite(
                    body: "Changed",
                    preserving: parsed,
                    fallbackName: "Fallback",
                    fallbackDescription: "Fallback"
                ).content
                let expectedFrontmatter = "---\n\(acceptedFrontmatter)\n---\n"
                    .replacingOccurrences(of: "\n", with: lineEnding)
                let expectedTrailingLineBreaks = String(repeating: lineEnding, count: terminalCount)
                XCTAssertEqual(
                    rewritten,
                    expectedFrontmatter + "Changed" + expectedTrailingLineBreaks,
                    "lineEnding=\(lineEnding.debugDescription), terminalCount=\(terminalCount)"
                )
                XCTAssertEqual(
                    SkillParser.parse(rewritten).preservedFrontmatter?.source,
                    parsed.preservedFrontmatter?.source
                )
            }
        }

        assertClosingFenceSeparatorCases(frontmatter: acceptedFrontmatter)

        let fallbacks = [
            "---\n---\nBody\n",
            "---\nname: Missing fence\nBody\n",
            "Plain body\n---\nRule\n"
        ]
        for source in fallbacks {
            let parsed = SkillParser.parse(source)
            XCTAssertNil(parsed.name)
            XCTAssertEqual(parsed.body, source)
        }
    }

    func testMegabyteSlowConstructionFrontmatterFallsBackQuickly() {
        let fixtures = [
            CheckedYAMLLoaderTests.manyExplicitMergeTagDocument(),
            CheckedYAMLLoaderTests.explicitMergeTagDocument(),
            CheckedYAMLLoaderTests.aliasedLongScalarDocument(),
            CheckedYAMLLoaderTests.aliasedLongTagDocument(),
            CheckedYAMLLoaderTests.nestedMergeDocument(levels: 62, keyCount: 238_000),
            CheckedYAMLLoaderTests.aliasedNestedMergeDocument(levels: 62)
        ]

        for frontmatter in fixtures {
            let content = "---\n" + frontmatter + "---\nBody\n"
            let start = Self.threadCPUTime()
            let parsed = SkillParser.parse(content)
            XCTAssertLessThan(Self.threadCPUTime() - start, 1)
            XCTAssertNil(parsed.name)
            XCTAssertEqual(parsed.body, content)
        }
    }

    func testMegabyteShortMergeAliasFloodFallsBackQuickly() {
        let itemCount = 330_000
        let content = Self.skillDocument(
            frontmatter: "name: Flood\ndescription: Flood\ntags: [&a <<,"
                + String(repeating: "*a,", count: itemCount - 1)
                + "]\n"
        )

        XCTAssertGreaterThan(content.utf8.count, 980_000)
        XCTAssertLessThan(content.utf8.count, 1_000_000)
        let start = Self.threadCPUTime()
        let parsed = SkillParser.parse(content)
        XCTAssertLessThan(Self.threadCPUTime() - start, 1)
        XCTAssertNil(parsed.name)
        XCTAssertEqual(parsed.body, content)
    }

    func testMegabyteShortMergeScalarsStayWithinFlatMappingRatio() {
        let itemCount = 330_000
        let anchoredItemCount = 123_000
        let plain = Self.skillDocument(
            frontmatter: "name: Short\ndescription: Short\ntags: ["
                + String(repeating: "<<,", count: itemCount)
                + "]\n"
        )
        let anchored = Self.skillDocument(
            frontmatter: "name: Anchored\ndescription: Anchored\ntags: ["
                + Self.distinctAnchoredMergeScalars(count: anchoredItemCount)
                + "]\n"
        )

        XCTAssertGreaterThan(plain.utf8.count, 980_000)
        XCTAssertLessThan(plain.utf8.count, 1_000_000)
        XCTAssertGreaterThan(anchored.utf8.count, 980_000)
        XCTAssertLessThan(anchored.utf8.count, 1_000_000)

        let baseline = Self.flatSkillMappingDocument(
            approximatelyMatching: max(plain.utf8.count, anchored.utf8.count)
        )
        assertRelativeParseTime(
            of: plain,
            comparedWith: baseline,
            named: "SkillParser plain short merge scalars"
        ) { parsed in
            XCTAssertEqual(parsed.name, "Short")
            XCTAssertEqual(parsed.tags.count, itemCount)
            XCTAssertTrue(parsed.tags.allSatisfy { $0 == "<<" })
        }
        assertRelativeParseTime(
            of: anchored,
            comparedWith: baseline,
            named: "SkillParser distinct anchored merge scalars"
        ) { parsed in
            XCTAssertEqual(parsed.name, "Anchored")
            XCTAssertEqual(parsed.tags.count, anchoredItemCount)
            XCTAssertTrue(parsed.tags.allSatisfy { $0 == "<<" })
        }
    }

    func testWorstAcceptedMergeShapeStaysWithinFlatMappingRatio() {
        let frontmatter = "name: Merge\ndescription: Merge\nmetadata: "
            + CheckedYAMLLoaderTests.nestedMergeDocument(
                levels: CheckedYAMLLoader.maximumMergeNestingDepth,
                keyCount: 238_000
            )
            + "\n"
        let content = Self.skillDocument(frontmatter: frontmatter)

        XCTAssertGreaterThan(content.utf8.count, 950_000)
        XCTAssertLessThan(content.utf8.count, 1_000_000)
        let baseline = Self.flatSkillMappingDocument(
            approximatelyMatching: content.utf8.count
        )
        assertRelativeParseTime(
            of: content,
            comparedWith: baseline,
            named: "SkillParser four-level dense merge mapping"
        ) { parsed in
            XCTAssertEqual(parsed.name, "Merge")
        }
    }

    func testCheckedLoaderAcceptedShapesStayWithinFlatMappingRatio() throws {
        let itemCount = 330_000
        let shortScalars = "tags: ["
            + String(repeating: "<<,", count: itemCount)
            + "]\n"
        let denseMerge = CheckedYAMLLoaderTests.nestedMergeDocument(
            levels: CheckedYAMLLoader.maximumMergeNestingDepth,
            keyCount: 238_000
        )
        let baseline = Self.flatYAMLMappingDocument(
            approximatelyMatching: max(shortScalars.utf8.count, denseMerge.utf8.count)
        )

        XCTAssertGreaterThan(shortScalars.utf8.count, 980_000)
        XCTAssertLessThan(shortScalars.utf8.count, 1_000_000)
        XCTAssertGreaterThan(denseMerge.utf8.count, 950_000)
        XCTAssertLessThan(denseMerge.utf8.count, 1_000_000)

        try assertRelativeLoadTime(
            of: shortScalars,
            comparedWith: baseline,
            named: "CheckedYAMLLoader plain short merge scalars"
        ) { loaded in
            let tags = (loaded as? [String: Any])?["tags"] as? [Any]
            XCTAssertEqual(tags?.count, itemCount)
            XCTAssertTrue(tags?.allSatisfy { $0 as? String == "<<" } == true)
        }
        try assertRelativeLoadTime(
            of: denseMerge,
            comparedWith: baseline,
            named: "CheckedYAMLLoader four-level dense merge mapping"
        ) { loaded in
            XCTAssertEqual((loaded as? [String: Any])?.count, 238_000)
        }
    }

    private static func skillDocument(frontmatter: String) -> String {
        "---\n" + frontmatter + "---\nBody\n"
    }

    private static func distinctAnchoredMergeScalars(count: Int) -> String {
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var scalars = ""
        scalars.reserveCapacity(count * 8)
        for value in 0..<count {
            scalars.append("&")
            scalars.append(digits[(value / (62 * 62)) % 62])
            scalars.append(digits[(value / 62) % 62])
            scalars.append(digits[value % 62])
            scalars.append(" <<,")
        }
        return scalars
    }

    private func assertRelativeParseTime(
        of document: String,
        comparedWith baseline: String,
        named name: String,
        validate: (ParsedSkill) -> Void
    ) {
        assertRelativeTime(
            of: document,
            comparedWith: baseline,
            named: name,
            operation: SkillParser.parse,
            validate: validate
        )
    }

    private func assertRelativeLoadTime(
        of document: String,
        comparedWith baseline: String,
        named name: String,
        validate: (Any?) -> Void
    ) throws {
        try assertRelativeTime(
            of: document,
            comparedWith: baseline,
            named: name,
            operation: CheckedYAMLLoader.load,
            validate: validate
        )
    }

    private func assertRelativeTime<Value>(
        of document: String,
        comparedWith baseline: String,
        named name: String,
        operation: (String) throws -> Value,
        validate: (Value) -> Void
    ) rethrows {
        var bestShape = TimeInterval.greatestFiniteMagnitude
        var bestBaseline = TimeInterval.greatestFiniteMagnitude
        for iteration in 0..<3 {
            let shape = try Self.measureThreadCPUTime { try operation(document) }
            let flat = try Self.measureThreadCPUTime { try operation(baseline) }
            bestShape = min(bestShape, shape.duration)
            bestBaseline = min(bestBaseline, flat.duration)

            if iteration == 0 { validate(shape.value) }
        }

        let ratio = bestShape / bestBaseline
        let evidence = "PLAN38_TIMING \(Self.buildConfiguration) \(name): "
            + "shape=\(bestShape) flat=\(bestBaseline) ratio=\(ratio)"
        print(evidence)
        XCTContext.runActivity(named: evidence) { _ in }
        XCTAssertLessThanOrEqual(ratio, 1.5, "\(name) ratio was \(ratio)")
    }

    // Both results stay alive through the ending clock read and are released outside the measured window.
    private static func measureThreadCPUTime<Value>(
        _ operation: () throws -> Value
    ) rethrows -> (value: Value, duration: TimeInterval) {
        let start = threadCPUTime()
        let value = try operation()
        let duration = withExtendedLifetime(value) { threadCPUTime() - start }
        return (value, duration)
    }

    // Parsing is synchronous on this thread; descheduled time and other threads' work must not count.
    private static func threadCPUTime() -> TimeInterval {
        var time = timespec()
        precondition(clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time) == 0)
        return TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000
    }

    private func assertClosingFenceSeparatorCases(frontmatter: String) {
        for lineEnding in ["\n", "\r\n"] {
            for closingEnding in ["", "\r"] {
                let source = ("---\n" + frontmatter + "\n---")
                    .replacingOccurrences(of: "\n", with: lineEnding) + closingEnding
                let parsed = SkillParser.parse(source)
                let behavior = closingEnding == "\r"
                    ? "lone CR completes the fence separator but adds no terminal break"
                    : "unterminated fence gains the preferred separator without a terminal break"
                let name = "lineEnding=\(lineEnding.debugDescription), closingEnding=\(closingEnding.debugDescription); "
                    + behavior
                XCTAssertEqual(parsed.name, "Sweep", name)
                XCTAssertEqual(parsed.preservedFile?.bodyPrefix, source, name)
                let rewritten = SkillSerializer.rewrite(
                    body: "Changed",
                    preserving: parsed,
                    fallbackName: "Fallback",
                    fallbackDescription: "Fallback"
                ).content
                let separator = closingEnding == "\r" ? "\n" : lineEnding
                XCTAssertEqual(rewritten, source + separator + "Changed", name)
            }
        }
    }

    private static func flatSkillMappingDocument(approximatelyMatching byteCount: Int) -> String {
        let empty = skillDocument(
            frontmatter: "name: Flat\ndescription: Flat\nmetadata: {}\n"
        )
        let availableBytes = max(0, byteCount - empty.utf8.count)
        let keyCount = min(238_000, availableBytes / 4)
        return skillDocument(
            frontmatter: "name: Flat\ndescription: Flat\nmetadata: "
                + CheckedYAMLLoaderTests.bareFlowMapping(keyCount: keyCount)
                + "\n"
        )
    }

    private static func flatYAMLMappingDocument(approximatelyMatching byteCount: Int) -> String {
        let keyCount = min(238_000, max(0, byteCount - 2) / 4)
        return CheckedYAMLLoaderTests.bareFlowMapping(keyCount: keyCount)
    }

    private static var buildConfiguration: String {
        #if DEBUG
        "Debug"
        #else
        "Release"
        #endif
    }
}
