import XCTest
import Yams
@testable import Pensieve

final class FrontmatterTrustTests: XCTestCase {
    func testEventMetadataDistinguishesLiteralPunctuationFromYAMLAnchors() throws {
        for syntax in FrontmatterRewriteFixture.syntaxCases {
            let source = syntax.document(name: "A")
            let parsed = SkillParser.parse(source)
            let file = try XCTUnwrap(parsed.preservedFile, syntax.label)
            let document = try CheckedYAMLLoader.composeAndLoad(yaml: file.frontmatterSource)
            XCTAssertNotNil(document.root, syntax.label)
            XCTAssertEqual(document.hasAnchorsOrAliases, !syntax.trusted, syntax.label)
            XCTAssertEqual(try XCTUnwrap(parsed.preservedFrontmatter, syntax.label).entriesAreTrustworthy,
                           syntax.trusted, syntax.label)
        }
    }

    func testGeneratedSweepTrustsOnlyMatchingKeyPositions() throws {
        let fixtures = FrontmatterRewriteFixture.sweep
        XCTAssertEqual(fixtures.count, 120)
        for fixture in fixtures {
            let parsed = SkillParser.parse(fixture.source)
            if fixture.header == nil || fixture.label.hasPrefix("empty,") {
                XCTAssertNil(parsed.preservedFrontmatter, fixture.label)
                if fixture.header == nil {
                    XCTAssertNil(parsed.preservedFile, fixture.label)
                    XCTAssertFalse(parsed.hasRequiredFrontmatter, fixture.label)
                    XCTAssertEqual(parsed.body, fixture.source, fixture.label)
                }
                continue
            }
            let frontmatter = try XCTUnwrap(parsed.preservedFrontmatter, fixture.label)
            XCTAssertEqual(frontmatter.entriesAreTrustworthy, fixture.trustsEntries, fixture.label)
            if frontmatter.entriesAreTrustworthy {
                let mapping = try XCTUnwrap(try CheckedYAMLLoader.composeAndLoad(yaml: frontmatter.source).root?.mapping)
                XCTAssertEqual(mapping.count, frontmatter.entries.count, fixture.label)
                for (pair, entry) in zip(mapping, frontmatter.entries) {
                    XCTAssertEqual(pair.key.string, entry.key, fixture.label)
                    let beforeEntry = frontmatter.source[..<entry.sourceRange.lowerBound]
                    XCTAssertEqual(pair.key.mark?.line, beforeEntry.unicodeScalars.filter { $0 == "\n" }.count + 1,
                                   fixture.label)
                    XCTAssertEqual(pair.key.mark?.column, 1, fixture.label)
                }
            }
        }
    }

    func testMultilineFlowMappingIsNotTrustworthy() throws {
        let yaml = "{\nname: A,\ndescription: D,\nlicense: MIT\n}"
        let loaded = try CheckedYAMLLoader.composeAndLoad(yaml: yaml)
        XCTAssertTrue(loaded.rootIsFlowMapping)
        XCTAssertEqual((loaded.value as? [String: Any])?["name"] as? String, "A")
        let parsed = SkillParser.parse("---\n" + yaml + "\n---\nBody")
        XCTAssertFalse(try XCTUnwrap(parsed.preservedFrontmatter).entriesAreTrustworthy)
    }

    func testMixedLineBreaksInsideLFFencesRejectOddBreaks() throws {
        for ending in FrontmatterRewriteFixture.lineBreaks {
            let source = "---\nname: A\nlicense: MIT" + ending + "description: D\n---\nBody"
            let parsed = SkillParser.parse(source)
            let trusted = ["\n", "\r\n"].contains(ending)
            XCTAssertEqual(try XCTUnwrap(parsed.preservedFrontmatter).entriesAreTrustworthy, trusted,
                           ending.debugDescription)
            let normalized = SkillSerializer.normalizeIdentity(name: "New", description: "New description", parsed: parsed)
            if trusted {
                XCTAssertEqual(normalized, source.replacingOccurrences(of: "name: A", with: "name: New")
                    .replacingOccurrences(of: "description: D", with: "description: New description"))
            } else {
                XCTAssertNil(normalized, ending.debugDescription)
            }
        }
    }

    func testGeneratedIdentitySweepChangesOnlyIdentityOrKeepsSource() throws {
        for fixture in FrontmatterRewriteFixture.sweep {
            let parsed = SkillParser.parse(fixture.source)
            let normalized = SkillSerializer.normalizeIdentity(name: "New", description: "New description", parsed: parsed)
            if fixture.trustsEntries {
                let expected = fixture.source.replacingOccurrences(of: "name: A", with: "name: New")
                    .replacingOccurrences(of: "description: D", with: "description: New description")
                XCTAssertEqual(try XCTUnwrap(normalized, fixture.label), expected, fixture.label)
            } else if parsed.preservedFile != nil {
                XCTAssertNil(normalized, fixture.label)
            } else {
                let ending = fixture.lineEnding == "\r\n" ? "\r\n" : "\n"
                let expected = "---\(ending)name: New\(ending)description: New description\(ending)---"
                    + ending + ending + fixture.source
                XCTAssertEqual(try XCTUnwrap(normalized, fixture.label), expected, fixture.label)
            }
        }
    }

    func testGeneratedHeaderAndIdentityChangesAcrossPunctuationAndDocumentShapes() throws {
        let fixtures = FrontmatterRewriteFixture.headerSweep
        XCTAssertEqual(fixtures.count, 330)
        for fixture in fixtures {
            if fixture.trusted {
                let rewritten = try SkillDocumentEditing.rewrite(draft: fixture.draft, original: fixture.original,
                                                                 name: "A", description: "D")
                XCTAssertTrue(rewritten.didChange, fixture.label)
                XCTAssertEqual(Data(rewritten.content.utf8), Data(fixture.expected.utf8), fixture.label)
            } else {
                XCTAssertThrowsError(try SkillDocumentEditing.rewrite(draft: fixture.draft, original: fixture.original,
                                                                     name: "A", description: "D"), fixture.label) {
                    XCTAssertEqual($0.localizedDescription,
                        "Couldn't save. The frontmatter at the top of the file can't be read.", fixture.label)
                }
            }
            let normalized = SkillSerializer.normalizeIdentity(name: "New", description: "New description",
                                                               parsed: SkillParser.parse(fixture.original))
            XCTAssertEqual(normalized.map { Data($0.utf8) }, fixture.expectedIdentity.map { Data($0.utf8) }, fixture.label)
        }
    }

    func testIdentityRewriteValidatesEvenForgedTrustMetadata() throws {
        let fixture = try XCTUnwrap(FrontmatterRewriteFixture.sweep.first { $0.label.hasPrefix("quoted continuation,") })
        var parsed = SkillParser.parse(fixture.source)
        let frontmatter = try XCTUnwrap(parsed.preservedFrontmatter)
        parsed.preservedFrontmatter = PreservedFrontmatter(
            source: frontmatter.source, entries: frontmatter.entries, entriesAreTrustworthy: true
        )
        XCTAssertNil(SkillSerializer.normalizeIdentity(name: "New", description: "New description", parsed: parsed))
    }

    func testIdentityRewriteRejectsLossOfAnotherEntryEvenWhenOutputParses() throws {
        var parsed = SkillParser.parse("---\nname: A\nlicense: MIT\ndescription: D\n---\nBody")
        let frontmatter = try XCTUnwrap(parsed.preservedFrontmatter)
        let entries = frontmatter.entries
        XCTAssertEqual(entries.count, 3)
        parsed.preservedFrontmatter = PreservedFrontmatter(
            source: frontmatter.source,
            entries: [
                .init(key: "name", sourceRange: entries[0].sourceRange.lowerBound..<entries[2].sourceRange.lowerBound),
                entries[2]
            ],
            entriesAreTrustworthy: true
        )
        XCTAssertNil(SkillSerializer.normalizeIdentity(name: "New", description: "New description", parsed: parsed))
    }
}
