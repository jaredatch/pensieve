import AppKit
import XCTest
@testable import Pensieve

extension ThirdPartyNoticesTests {
    func testCheckoutLocationFollowsTestHost() throws {
        try withFixture { root in
            let checkouts = root + "/SourcePackages/checkouts"
            try fileService.createDirectory(at: checkouts)
            for configuration in ["Debug", "Release"] {
                let host = URL(fileURLWithPath: root + "/Build/Products/" + configuration + "/Pensieve.app")
                XCTAssertEqual(try inventory.checkouts(for: host), checkouts)
            }
        }
    }

    func testMissingCheckoutsNameHostBuildPath() throws {
        try withFixture { root in
            let host = URL(fileURLWithPath: root + "/Build/Products/Debug/Pensieve.app")
            assertMissing("Missing Swift package checkouts for test host: \(root)/SourcePackages/checkouts") {
                _ = try inventory.checkouts(for: host)
            }
        }
    }

    func testUnrecognizedHostLocationIsNamed() throws {
        try withFixture { root in
            let host = URL(fileURLWithPath: root + "/Pensieve.app")
            assertMissing("Cannot locate Swift package checkouts from test host: \(host.path)") {
                _ = try inventory.checkouts(for: host)
            }
        }
    }

    func testLicenseExtractionAcceptsCRLFAndKeepsOtherSeparators() throws {
        let license = "Copyright A\u{000C}B\u{001C}C\u{001D}D\u{001E}E\u{0085}F\u{2028}G\u{2029}H."
        let source = "### libYAML\r\n```text\r\n\(license)\r\n```\r\n"
        let notices = try parseNotices(source)
        XCTAssertEqual(notices.licenseBlocks.map(\.text), [license])
        let decoded = try decodeCredits(Data(renderFixture(source).utf8))
        XCTAssertTrue(decoded.string.contains(license))
    }

    func testDocumentationLicenseNamesAreRequired() throws {
        for name in ["ThirdPartyNotices.txt", "OpenSourceLicenses.txt", "LICENSE2", "COPYRIGHTS", "UNLICENSE",
                     "VendorCopying.markdown", "vendorNOTICE.rst", "license.html", "pReFiXlIcEnCe.md"] {
            try assertVendorNoticeRequired(named: name)
        }
    }

    func testSourceAndToolingLicenseNamesAreIgnored() throws {
        for name in ["check-license.sh", "update_copyright.py", "Notice.swift", "license_test.go", "notices.json"] {
            try withSwiftFixture { root in
                try fileService.writeFile(at: root + "/example/" + name, content: "Tooling, not attribution.")
                XCTAssertNoThrow(try checkSwiftFixture(root: root, credits: "Example license."), name)
            }
        }
    }

    func testNestedEditorVersionsHaveSeparateNotices() throws {
        try withFixture { root in
            try fileService.writeFile(at: root + "/lock.json", content: """
            {"packages":{"node_modules/foo":{"version":"1.2.0","license":"MIT"},
            "node_modules/bar/node_modules/foo":{"version":"2.0.0","license":"MIT"}}}
            """)
            let first = "Copyright First. Permission is hereby granted. THE SOFTWARE IS PROVIDED AS IS."
            let second = "Copyright Second. Permission is hereby granted. THE SOFTWARE IS PROVIDED AS IS."
            let notices = "- `foo` 1.2.0\n```text\n\(first)\n```\n- `foo` 2.0.0\n```text\n\(second)\n```\n"
            XCTAssertNoThrow(try inventory.checkEditorPackages(lockfile: root + "/lock.json", notices: parseNotices(notices),
                                                               credits: "foo\n" + first + "\n" + second))
            assertMissing("Missing bundled license for editor package foo") {
                try inventory.checkEditorPackages(lockfile: root + "/lock.json", notices: parseNotices(notices),
                                                   credits: "foo\n" + first)
            }
        }
    }

    func testEditorAuditAcceptsCRLFNotices() throws {
        try withEditorFixture(versions: ["one": "1.0.1"]) { root, notices, credits in
            XCTAssertNoThrow(try inventory.checkEditorPackages(
                lockfile: root + "/lock.json", notices: parseNotices(notices.replacingOccurrences(of: "\n", with: "\r\n")),
                credits: credits
            ))
        }
    }

    func testRendererRunsUnderSystemPython() throws {
        let source = "# Notices\r\n```text\r\nCopyright System Python.\r\n```\r\n"
        let decoded = try decodeCredits(Data(renderFixture(source).utf8))
        XCTAssertEqual(decoded.string.trimmingCharacters(in: .whitespacesAndNewlines),
                       "Notices\nCopyright System Python.")
    }

    func testRendererStripsMarkdownFromEveryHeadingLevel() throws {
        for level in 1...6 {
            let rtf = try renderFixture(String(repeating: "#", count: level) + " [Foo](https://x) `Bar`\n")
            let decoded = try decodeCredits(Data(rtf.utf8))
            XCTAssertEqual(decoded.string.trimmingCharacters(in: .whitespacesAndNewlines), "Foo (https://x) Bar")
            let font = try XCTUnwrap(decoded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask), "Heading level \(level)")
        }
    }
}
