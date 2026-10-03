import AppKit
import XCTest
@testable import Pensieve

extension ThirdPartyNoticesTests {
    func testVendoredNOTICESIsRequired() throws {
        try assertVendorNoticeRequired(named: "NOTICES")
    }

    func testVendoredNOTICESMarkdownIsRequired() throws {
        try assertVendorNoticeRequired(named: "NOTICES.md")
    }

    func testVendoredLICENSESTextIsRequired() throws {
        try assertVendorNoticeRequired(named: "LICENSES.txt")
    }

    func testVendoredCOPYRIGHTIsRequired() throws {
        try assertVendorNoticeRequired(named: "COPYRIGHT")
    }

    func testVendoredPrefixedNOTICESIsRequired() throws {
        try assertVendorNoticeRequired(named: "THIRD_PARTY_NOTICES")
    }

    func testYamsBumpRequiresLibYAMLNoticeReview() throws {
        try withYamsFixture(version: "6.2.3") { root in
            assertMissing("Recheck libYAML notice for Swift package yams 6.2.3; audited Yams version is 6.2.2") {
                try checkYamsFixture(root: root)
            }
        }
    }

    func testAuditedYamsVersionIsAccepted() throws {
        try withYamsFixture(version: "6.2.2") { root in
            try checkYamsFixture(root: root)
        }
    }

    func testEditorVersionMismatchIsNamed() throws {
        for listed in ["1.0.0", "1.0.10", ""] {
            try withEditorFixture(versions: ["one": "1.0.1"], listedVersions: ["one": listed]) { root, notices, credits in
                let found = listed.isEmpty ? "<missing>" : listed
                assertMissing("Version mismatch for editor package one: lockfile 1.0.1, notice \(found)") {
                    try inventory.checkEditorPackages(lockfile: root + "/lock.json", notices: notices, credits: credits)
                }
            }
        }
    }

    func testMatchingEditorVersionsAreAccepted() throws {
        try withEditorFixture(versions: ["one": "1.0.1", "two": "2.0.0"]) { root, notices, credits in
            try inventory.checkEditorPackages(lockfile: root + "/lock.json", notices: notices, credits: credits)
        }
    }

    func testEditorCreditsAreNormalizedOnce() throws {
        try withEditorFixture(versions: ["one": "1.0.1", "two": "2.0.0"]) { root, notices, credits in
            var calls = 0
            let counted = NoticeInventory(fileService: fileService, normalizeCredits: { text in
                XCTAssertEqual(text, credits)
                calls += 1
                return NoticeInventory.normalized(text)
            })
            try counted.checkEditorPackages(lockfile: root + "/lock.json", notices: notices, credits: credits)
            XCTAssertEqual(calls, 1, "Normalize the credits once for the complete editor inventory")
        }
    }

    func testRendererPreservesLicenseSeparators() throws {
        for scalar in licenseSeparators {
            let separator = String(scalar)
            let escaped = "\\u\(scalar.value)?"
            let rtf = try renderFixture("```text\nCopyright A\(separator)B.\n```\n")
            XCTAssertTrue(rtf.contains("Copyright A\(escaped)B.\\line"), "Lost license separator U+\(scalar.value)")
        }
    }

    func testRendererKeepsSeparatorsOnLiteralFenceLines() throws {
        for scalar in licenseSeparators {
            let separator = String(scalar)
            let escaped = "\\u\(scalar.value)?"
            let rtf = try renderFixture("```text\n```text\(separator)literal\n```\(separator)literal\n```\n")
            XCTAssertTrue(rtf.contains("```text\(escaped)literal\\line"), "Opening fence lost U+\(scalar.value)")
            XCTAssertTrue(rtf.contains("```\(escaped)literal\\line"), "Closing fence lost U+\(scalar.value)")
        }
    }

    func testRendererAcceptsCRLFLines() throws {
        let source = "# Notices\n```text\nCopyright {Fixture}.\n```\n"
        let lf = try renderFixture(source)
        let crlf = try renderFixture(source.replacingOccurrences(of: "\n", with: "\r\n"))
        XCTAssertEqual(crlf, lf)
        let decoded = try NSAttributedString(data: Data(crlf.utf8),
                                             options: [.documentType: NSAttributedString.DocumentType.rtf],
                                             documentAttributes: nil)
        XCTAssertEqual(decoded.string.trimmingCharacters(in: .whitespacesAndNewlines), "Notices\nCopyright {Fixture}.")
    }

    private var licenseSeparators: [Unicode.Scalar] {
        ["\u{000B}", "\u{000C}", "\u{001C}", "\u{001D}", "\u{001E}", "\u{0085}", "\u{2028}", "\u{2029}"]
    }

    private func assertVendorNoticeRequired(named name: String) throws {
        try withSwiftFixture { root in
            let vendor = root + "/example/Vendor/NewLibrary"
            let license = "Copyright Vendor. Unique required attribution."
            try fileService.createDirectory(at: vendor)
            try fileService.writeFile(at: vendor + "/" + name, content: license)
            assertMissing("Missing bundled license: example/Vendor/NewLibrary/\(name)") {
                try checkSwiftFixture(root: root, credits: "Example license.")
            }
            try checkSwiftFixture(root: root, credits: "Example license.\n" + license)
        }
    }

    private func withYamsFixture(version: String, operation: (String) throws -> Void) throws {
        try withFixture { root in
            try fileService.createDirectory(at: root + "/yams")
            try fileService.writeFile(at: root + "/yams/LICENSE", content: "Yams license.")
            try fileService.writeFile(at: root + "/resolved.json", content: """
            {"pins":[{"identity":"yams","state":{"version":"\(version)"}}]}
            """)
            try operation(root)
        }
    }

    private func checkYamsFixture(root: String) throws {
        try inventory.checkSwiftPackages(resolved: root + "/resolved.json", checkouts: root,
                                         notices: "[Yams](https://github.com/jpsim/Yams)", credits: "Yams license.")
    }

    private func withEditorFixture(versions: [String: String], listedVersions: [String: String]? = nil,
                                   operation: (String, String, String) throws -> Void) throws {
        try withFixture { root in
            let packages = Dictionary(uniqueKeysWithValues: versions.map { name, version in
                ("node_modules/" + name, ["version": version, "license": "MIT"])
            })
            let data = try JSONSerialization.data(withJSONObject: ["packages": packages])
            let json = try XCTUnwrap(String(data: data, encoding: .utf8))
            try fileService.writeFile(at: root + "/lock.json", content: json)
            let entries = versions.keys.sorted().map { "- `\($0)` \((listedVersions ?? versions)[$0] ?? "")" }
            let license = "Copyright Fixture. Permission is hereby granted. THE SOFTWARE IS PROVIDED AS IS."
            let notices = entries.joined(separator: "\n") + "\n```text\n" + license + "\n```\n"
            try operation(root, notices, versions.keys.sorted().joined(separator: " ") + "\n" + license)
        }
    }

    private func renderFixture(_ source: String) throws -> String {
        var rtf = ""
        try withFixture { root in
            try fileService.writeFile(at: root + "/source.md", content: source)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [sourceRoot + "/script/credits.py", root + "/source.md", root + "/Credits.rtf"]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            rtf = try fileService.readFile(at: root + "/Credits.rtf")
        }
        return rtf
    }
}
