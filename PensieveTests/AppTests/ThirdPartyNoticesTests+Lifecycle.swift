import CryptoKit
import XCTest
@testable import Pensieve

extension ThirdPartyNoticesTests {
    func testBuildPhaseIgnoresPythonOnPATH() throws {
        let data = try fileService.readData(at: sourceRoot + "/Pensieve.xcodeproj/project.pbxproj")
        let project = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let objects = try XCTUnwrap(project["objects"] as? [String: [String: Any]])
        let phase = try XCTUnwrap(objects.values.first { $0["name"] as? String == "Generate About credits" })
        let shell = try XCTUnwrap(phase["shellPath"] as? String)
        let command = try XCTUnwrap(phase["shellScript"] as? String)
        try withFixture { root in
            try fileService.createDirectory(at: root + "/script")
            try fileService.writeFile(at: root + "/script/credits.py",
                                      content: fileService.readFile(at: sourceRoot + "/script/credits.py"))
            try fileService.writeFile(at: root + "/THIRD-PARTY-NOTICES.md", content: "# Fixture\n")
            try fileService.createDirectory(at: root + "/bin")
            try fileService.writeExecutableFile(at: root + "/bin/python3", content: "#!/bin/sh\nexit 91\n")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-c", command]
            process.environment = ["PATH": root + "/bin:/usr/bin:/bin", "SRCROOT": root,
                                   "TARGET_BUILD_DIR": root, "UNLOCALIZED_RESOURCES_FOLDER_PATH": "Resources"]
            let result = try runCreditsProcess(process, fixtureRoot: root)
            XCTAssertEqual(result.status, 0, result.error)
            XCTAssertTrue(fileService.fileExists(at: root + "/Resources/Credits.rtf"))
        }
    }

    func testCreditsProcessCapturesLargeStderrCompletely() throws {
        let code = largeStderrProgram
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", code]
        let result = try runCreditsProcess(process)
        XCTAssertEqual(result.status, 0, result.error)
        XCTAssertEqual(result.output, "DONE")
        XCTAssertEqual(result.error.count, 262144)
    }

    var largeStderrProgram: String {
        """
        import sys
        sys.stderr.write('E'*262144); sys.stderr.flush(); sys.stdout.write('DONE'); sys.stdout.flush()
        """
    }

    func testPackageAuditEnforcesYamsVersionWithoutCallerChaining() throws {
        try withFixture { root in
            try fileService.createDirectory(at: root + "/yams")
            try fileService.writeFile(at: root + "/yams/LICENSE", content: "Yams license.")
            try fileService.writeFile(at: root + "/resolved.json", content: """
            {"pins":[{"identity":"yams","state":{"version":"6.2.3"}}]}
            """)
            assertMissing("Recheck libYAML notice for Swift package yams 6.2.3; audited Yams version is 6.2.2") {
                try inventory.checkSwiftPackages(resolved: root + "/resolved.json", checkouts: root,
                    notices: parseNotices("[Yams](https://github.com/jpsim/Yams)"), credits: "Yams license.")
            }
        }
    }

    func testLinkedYamsStillRequiresLibYAMLContent() throws {
        try withFixture { root in
            try fileService.createDirectory(at: root + "/yams")
            try fileService.writeFile(at: root + "/yams/LICENSE", content: "Yams license.")
            try fileService.writeFile(at: root + "/resolved.json", content: """
            {"pins":[{"identity":"yams","state":{"version":"6.2.2"}}]}
            """)
            assertMissing("Missing libYAML notice for Swift package yams 6.2.2") {
                try inventory.checkSwiftPackages(resolved: root + "/resolved.json", checkouts: root,
                    notices: parseNotices("[Yams](https://github.com/jpsim/Yams)"), credits: "Yams license.")
            }
        }
    }

    func testEditorLicenseCannotCrossHeading() throws {
        try withEditorFixture(versions: ["one": "1.0.1"]) { root, _, credits in
            let body = "Copyright Fixture. Permission is hereby granted. THE SOFTWARE IS PROVIDED AS IS."
            for heading in ["# Later", "## Later", "### Later", "#### Later", "##### Later", "###### Later"] {
                let notices = "- `one` 1.0.1\n" + heading + "\n```text\n" + body + "\n```\n"
                assertMissing("Missing or unsupported license for editor package one") {
                    try inventory.checkEditorPackages(lockfile: root + "/lock.json",
                                                       notices: parseNotices(notices), credits: credits)
                }
            }
        }
    }

    func testInvalidExemptionReasonNamesEntry() throws {
        for reason in ["", "  ", "first\nsecond", "first\rsecond", "first\u{2028}second"] {
            try withSwiftFixture { root in
                let exemption = NoticeInventory.LicenseExemption(package: "example", path: "notice-faq.md", reason: reason,
                                                                  sha256: fixtureDigest("FAQ fixture."))
                assertMissing("Invalid license exemption: example/notice-faq.md: reason must be nonempty and single-line") {
                    try checkExemptionFixture(root: root, exemptions: [exemption])
                }
            }
        }
    }

    func testUnusedExemptionNamesEntry() throws {
        try withSwiftFixture { root in
            let exemption = NoticeInventory.LicenseExemption(package: "example", path: "notice-faq.md", reason: "FAQ fixture.",
                                                              sha256: fixtureDigest("FAQ fixture."))
            assertMissing("Unused license exemption: example/notice-faq.md; remove or review the entry") {
                try checkExemptionFixture(root: root, exemptions: [exemption])
            }
        }
    }

    func testChangedExemptedFileRequiresReview() throws {
        try withSwiftFixture { root in
            let path = "notice-faq.md", original = "FAQ fixture."
            try fileService.writeFile(at: root + "/example/" + path, content: original)
            let exemption = NoticeInventory.LicenseExemption(package: "example", path: path, reason: "FAQ fixture.",
                                                              sha256: fixtureDigest(original))
            XCTAssertNoThrow(try checkExemptionFixture(root: root, exemptions: [exemption]))
            try fileService.writeFile(at: root + "/example/" + path, content: "Changed fixture.")
            let message = "Changed license exemption: example/notice-faq.md: SHA-256 expected "
                + fixtureDigest(original) + ", found " + fixtureDigest("Changed fixture.")
                + "; review the file and update the entry"
            assertMissing(message) { try checkExemptionFixture(root: root, exemptions: [exemption]) }
        }
    }

    func testInvalidExemptionDigestNamesEntry() throws {
        try withSwiftFixture { root in
            try fileService.writeFile(at: root + "/example/notice-faq.md", content: "FAQ fixture.")
            let exemption = NoticeInventory.LicenseExemption(package: "example", path: "notice-faq.md", reason: "FAQ fixture.",
                                                              sha256: "not-a-digest")
            assertMissing("Invalid license exemption: example/notice-faq.md: SHA-256 must be 64 hexadecimal characters") {
                try checkExemptionFixture(root: root, exemptions: [exemption])
            }
        }
    }

    func testRenderedLibYAMLLinkCannotReplaceSectionHeading() throws {
        let license = try pinnedLibYAMLFixture()
        let source = "[libYAML](https://github.com/yaml/libyaml), vendored by Yams.\n```text\n" + license + "\n```\n"
        let credits = try decodeCredits(Data(renderFixture(source).utf8))
        XCTAssertFalse(hasRenderedLibYAMLSection(credits, license: license), "The link alone is not a section heading")
        let plain = try decodeCredits(Data(renderFixture("libYAML\n```text\n" + license + "\n```\n").utf8))
        XCTAssertFalse(hasRenderedLibYAMLSection(plain, license: license), "A plain libYAML line is not a bold heading")
        let heading = try decodeCredits(Data(renderFixture("### libYAML\n```text\n" + license + "\n```\n").utf8))
        XCTAssertTrue(hasRenderedLibYAMLSection(heading, license: license), "The bold heading and its own license form a section")
    }

    func testRenderedLibYAMLHeadingCannotBorrowLaterLicense() throws {
        let license = try pinnedLibYAMLFixture()
        let source = "### libYAML\n```text\nChanged terms.\n```\n### Other vendor\n```text\n" + license + "\n```\n"
        let credits = try decodeCredits(Data(renderFixture(source).utf8))
        XCTAssertFalse(hasRenderedLibYAMLSection(credits, license: license), "The pinned license belongs to another section")
    }

    func testNoticeCacheTracksSourceContent() throws {
        try withFixture { root in
            let cache = NoticeFileCache()
            let nonce = UUID().uuidString
            let first = "Copyright First. " + nonce
            let changed = "Copyright Changed. " + nonce
            let before = creditsRendererRuns
            let path = root + "/THIRD-PARTY-NOTICES.md"
            try fileService.writeFile(at: path, content: "```text\n" + first + "\n```\n")
            XCTAssertEqual(try loadNotices(at: path, cache: cache).licenseBlocks.map(\.text), [first])
            XCTAssertEqual(try loadNotices(at: path, cache: cache).licenseBlocks.map(\.text), [first])
            XCTAssertEqual(creditsRendererRuns - before, 1, "A cache hit must not run credits.py again")
            try fileService.writeFile(at: path, content: "```text\n" + changed + "\n```\n")
            XCTAssertEqual(try loadNotices(at: path, cache: cache).licenseBlocks.map(\.text), [changed])
            XCTAssertEqual(creditsRendererRuns - before, 2)
        }
    }

    func testNoticeCacheDoesNotHideMissingSource() throws {
        try withFixture { root in
            let cache = NoticeFileCache()
            let path = root + "/THIRD-PARTY-NOTICES.md"
            try fileService.writeFile(at: path, content: "```text\nCopyright Cached.\n```\n")
            _ = try loadNotices(at: path, cache: cache)
            try fileService.deleteFile(at: path)
            XCTAssertThrowsError(try loadNotices(at: path, cache: cache))
        }
    }

    func testRemovedYamsAllowsLibYAMLInOtherProse() throws {
        for name in ["libYAML", "LibYAML", "LIBYAML"] {
            let source = "[" + name + "](https://example.invalid), used by another vendor.\n"
            XCTAssertNoThrow(try LibYAMLNoticeAudit.checkVendorVersion(pins: [], notices: parseNotices(source)))
        }
    }

    func testResolvedYamsAcceptsItsSectionWithNormalizedWhitespace() throws {
        let pins: [[String: Any]] = [["identity": "yams", "state": ["version": "6.2.2"]]]
        let license = try pinnedLibYAMLFixture()
        let spaced = license.replacingOccurrences(of: " ", with: " \t")
        for body in [license, spaced] {
            let source = "### libYAML\n```text\n" + body + "\n```\n"
            XCTAssertNoThrow(try LibYAMLNoticeAudit.checkVendorVersion(pins: pins, notices: parseNotices(source)))
            XCTAssertNoThrow(try LibYAMLNoticeAudit.checkVendorVersion(pins: pins,
                notices: parseNotices(source.replacingOccurrences(of: "\n", with: "\r\n"))))
        }
    }

    func testResolvedYamsRejectsAlteredLibYAMLBlockBesidePristineCopy() throws {
        let pins: [[String: Any]] = [["identity": "yams", "state": ["version": "6.2.2"]]]
        let license = try pinnedLibYAMLFixture()
        for other in ["", "### Other vendor\n```text\n" + license + "\n```\n"] {
            let source = "### libYAML\n```text\n" + license + " Changed terms.\n```\n" + other
            assertMissing("Missing libYAML notice for Swift package yams 6.2.2") {
                try LibYAMLNoticeAudit.checkVendorVersion(pins: pins, notices: parseNotices(source))
            }
        }
    }

    func testResolvedYamsRequiresExactLibYAMLSection() throws {
        let pins: [[String: Any]] = [["identity": "yams", "state": ["version": "6.2.2"]]]
        let license = try pinnedLibYAMLFixture()
        for prefix in ["", "## libYAML\n", "#### libYAML\n", "### LibYAML\n",
                       "### Other vendor\n", "Prose ### libYAML\n"] {
            assertMissing("Missing libYAML notice for Swift package yams 6.2.2") {
                try LibYAMLNoticeAudit.checkVendorVersion(pins: pins,
                    notices: parseNotices(prefix + "```text\n" + license + "\n```\n"))
            }
        }
    }

    func testLibYAMLSectionCannotBorrowLicensePastNextHeading() throws {
        let pins: [[String: Any]] = [["identity": "yams", "state": ["version": "6.2.2"]]]
        let license = try pinnedLibYAMLFixture()
        for marks in 1...6 {
            let source = "### libYAML\n[Upstream](https://example.invalid)\n"
                + String(repeating: "#", count: marks) + " Other vendor\n```text\n" + license + "\n```\n"
            assertMissing("Missing libYAML notice for Swift package yams 6.2.2") {
                try LibYAMLNoticeAudit.checkVendorVersion(pins: pins, notices: parseNotices(source))
            }
        }
    }

    func pinnedLibYAMLFixture() throws -> String {
        let path = try XCTUnwrap(Bundle(for: ThirdPartyNoticesTests.self).path(forResource: "libyaml-license", ofType: "txt"))
        return try fileService.readFile(at: path)
    }

    func fixtureDigest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func checkExemptionFixture(root: String, exemptions: [NoticeInventory.LicenseExemption]) throws {
        try NoticeInventory(fileService: fileService, exemptions: exemptions).checkSwiftPackages(
            resolved: root + "/resolved.json", checkouts: root,
            notices: parseNotices("[Example](https://github.com/vendor/example)"), credits: "Example license.")
    }

}
