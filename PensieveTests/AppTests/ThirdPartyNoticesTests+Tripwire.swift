import AppKit
import XCTest
@testable import Pensieve

extension ThirdPartyNoticesTests {
    func testLicenseSuffixCandidatesRequireNotices() throws {
        for name in ["COPYING.LIB", "COPYING.LESSER", "LICENSE.APACHE", "LICENSE.BSD", "LICENSE.MIT",
                     "NOTICE.apache2", "license.htm", "license.rtf"] {
            try assertVendorNoticeRequired(named: name)
        }
    }

    func testSourceScriptAndDataExtensionsAreExcluded() throws {
        let suffixes = NoticeInventory.excludedExtensions.sorted()
        for suffix in suffixes {
            try withSwiftFixture { root in
                try fileService.writeFile(at: root + "/example/notice." + suffix, content: "Tooling fixture.")
                XCTAssertNoThrow(try checkSwiftFixture(root: root, credits: "Example license."), suffix)
            }
        }
    }

    func testLicensingFAQIsARequiredCandidate() throws {
        try assertVendorNoticeRequired(named: "licensing-faq.md")
    }

    func testReviewedExemptionClearsOnlyItsCandidate() throws {
        for path in ["notice-faq.md", "licensing-faq.md"] {
            try withSwiftFixture { root in
                try fileService.writeFile(at: root + "/example/" + path, content: "FAQ fixture.")
                assertMissing("Missing bundled license: example/" + path) {
                    try checkSwiftFixture(root: root, credits: "Example license.")
                }
                let exemption = NoticeInventory.LicenseExemption(package: "example", path: path,
                                                                 reason: "FAQ contains no third-party attribution.",
                                                                 sha256: fixtureDigest("FAQ fixture."))
                let exempted = NoticeInventory(fileService: fileService, exemptions: [exemption])
                XCTAssertNoThrow(try exempted.checkSwiftPackages(resolved: root + "/resolved.json", checkouts: root,
                                 notices: parseNotices("[Example](https://github.com/vendor/example)"),
                                 credits: "Example license."))
            }
        }
    }

    func testUnreadableCandidateNamesItsPath() throws {
        try withSwiftFixture { root in
            try fileService.writeData(at: root + "/example/license-fixture.dmg", data: Data([0xFF]))
            XCTAssertThrowsError(try checkSwiftFixture(root: root, credits: "Example license.")) { error in
                XCTAssertTrue(String(describing: error).contains("example/license-fixture.dmg"), "\(error)")
            }
        }
    }

    func testEmptyLicenseBlockDoesNotConsumeLaterBlock() throws {
        let source = "```text\n```\n### Next\n```text\nCopyright Next.\n```\n"
        let document = try parseNotices(source)
        XCTAssertEqual(document.licenseBlocks.map(\.text), ["", "Copyright Next."])
    }

    func testNestedFenceAgreesWithRenderedBlock() throws {
        let source = "```text\nCopyright First.\n```text\nCopyright Second.\n```\n"
        let document = try parseNotices(source)
        XCTAssertEqual(document.licenseBlocks.map(\.text), ["Copyright First.\nCopyright Second."])
        let rtf = try renderFixture(source)
        XCTAssertFalse(rtf.contains("```text"))
    }

    func testLibYAMLHeadingIsAnExactLine() throws {
        for heading in ["#### libYAML", "prefix ### libYAML"] {
            let document = try parseNotices(heading + "\n```text\nCopyright Other.\n```\n")
            XCTAssertNil(document.license(inSection: "### libYAML"), heading)
        }
    }

    func testLibYAMLBlockCannotCrossNextHeading() throws {
        for heading in ["# Next", "## Next", "### Next", "#### Next", "##### Next", "###### Next"] {
            let document = try parseNotices("### libYAML\nNo license here.\n" + heading
                                             + "\n```text\nCopyright Other.\n```\n")
            XCTAssertNil(document.license(inSection: "### libYAML"), heading)
        }
    }

    func testBackticksDoNotTurnParagraphsIntoHeadings() throws {
        let decoded = try decodeCredits(Data(renderFixture("`# include` directives\n").utf8))
        XCTAssertEqual(decoded.string.trimmingCharacters(in: .whitespacesAndNewlines), "# include directives")
        let font = try XCTUnwrap(decoded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertFalse(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    }

    func testSevenHashMarksAreNotAHeading() throws {
        let decoded = try decodeCredits(Data(renderFixture("####### Literal\n").utf8))
        XCTAssertEqual(decoded.string.trimmingCharacters(in: .whitespacesAndNewlines), "####### Literal")
        let font = try XCTUnwrap(decoded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertFalse(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    }

    func testRemovedYamsNamesStaleLibYAMLNotice() throws {
        try withFixture { root in
            try fileService.writeFile(at: root + "/resolved.json", content: "{\"pins\":[]}")
            assertMissing("Stale libYAML notice: Yams is no longer resolved; remove its notice or audit the new vendor") {
                try inventory.checkSwiftPackages(resolved: root + "/resolved.json", checkouts: root,
                                                 notices: parseNotices("### libYAML\n```text\nCopyright Old vendor.\n```\n"),
                                                 credits: "")
            }
        }
    }

    func testRendererExportsItsLicenseBlocksAsJSON() throws {
        try withFixture { root in
            try fileService.writeFile(at: root + "/source.md", content: "```text\n```\n```text\nCopyright JSON.\n```\n")
            let result = try runCredits(arguments: ["--license-blocks", root + "/source.md"])
            XCTAssertEqual(result.status, 0, result.error)
            let blocks = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [[String: Any]])
            XCTAssertEqual(blocks.compactMap { $0["text"] as? String }, ["", "Copyright JSON."])
        }
    }

    func testRendererRejectsOldPythonWithClearMessage() throws {
        try withFixture { root in
            try fileService.writeFile(at: root + "/source.md", content: "# Notices\n")
            let result = try runCredits(arguments: [root + "/source.md", root + "/Credits.rtf"], pythonVersion: "3,5,0")
            XCTAssertNotEqual(result.status, 0)
            XCTAssertTrue(result.error.contains("credits.py requires Python 3.6 or later"), result.error)
            XCTAssertFalse(fileService.fileExists(at: root + "/Credits.rtf"))
        }
    }

    func testEditorLicenseExamplesAreNotPackageEntries() throws {
        try withEditorFixture(versions: ["one": "1.0.1"]) { root, _, credits in
            let notices = "```text\n- `one` 1.0.1\n```\n```text\n"
                + "Copyright Fixture. Permission is hereby granted. THE SOFTWARE IS PROVIDED AS IS.\n```\n"
            assertMissing("Missing notice for editor package one") {
                try inventory.checkEditorPackages(lockfile: root + "/lock.json", notices: parseNotices(notices),
                                                   credits: credits)
            }
        }
    }

}
