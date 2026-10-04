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
            assertMissing("Stale libYAML notice: Yams is no longer resolved; remove the ### libYAML section") {
                try inventory.checkSwiftPackages(resolved: root + "/resolved.json", checkouts: root,
                                                 notices: parseNotices("### libYAML\n```text\nCopyright Old vendor.\n```\n"),
                                                 credits: "")
            }
            XCTAssertNoThrow(try inventory.checkSwiftPackages(resolved: root + "/resolved.json", checkouts: root,
                                                              notices: parseNotices(""), credits: ""))
        }
    }

    func testRemovedYamsAllowsOtherVendorHeadings() throws {
        for heading in ["## libYAML", "#### libYAML", "### LibYAML", "Prose ### libYAML"] {
            XCTAssertNoThrow(try LibYAMLNoticeAudit.checkVendorVersion(pins: [], notices: parseNotices(heading + "\n")))
        }
    }

    func testRemovedYamsAllowsLibYAMLInVerbatimLicenseBlocks() throws {
        for name in ["libYAML", "LibYAML", "LIBYAML"] {
            let source = "### Other vendor\n```text\nCopyright " + name + ".\n### libYAML\n```\n"
            XCTAssertNoThrow(try LibYAMLNoticeAudit.checkVendorVersion(pins: [], notices: parseNotices(source)))
        }
    }

    func testSwiftAuditUsesOnlyReadOperations() throws {
        try withSwiftFixture { root in
            let path = "license-guard.bin", bytes = "Read only license fixture."
            try fileService.writeFile(at: root + "/example/" + path, content: bytes)
            let exemption = NoticeInventory.LicenseExemption(package: "example", path: path, reason: "Audit fixture.",
                                                              sha256: fixtureDigest(bytes))
            let files = NoticeUnreadableFiles(base: fileService, unreadable: root + "/unused-fault")
            try fileService.createDirectory(at: root + "/example/Vendor")
            try fileService.writeFile(at: root + "/example/Vendor/LICENSE", content: "Vendored license.")
            try fileService.writeFile(at: root + "/outside.txt", content: "Unbundled linked notice.")
            try fileService.createSymlink(at: root + "/example/notice-linked.txt", pointingTo: root + "/outside.txt")
            XCTAssertNoThrow(try NoticeInventory(fileService: files, exemptions: [exemption]).checkSwiftPackages(
                resolved: root + "/resolved.json", checkouts: root,
                notices: parseNotices("[Example](https://github.com/vendor/example)"),
                credits: "Example license. Vendored license."))
            XCTAssertEqual(files.readAttempts, [root + "/resolved.json", root + "/example/" + path])
            XCTAssertEqual(files.textReadAttempts, [root + "/example/LICENSE", root + "/example/Vendor/LICENSE"])
        }
    }

    func testUnreadableExemptCandidateNamesItsPath() throws {
        try withSwiftFixture { root in
            let path = "license-fixture.dmg"
            try fileService.writeFile(at: root + "/example/" + path, content: "Fixture bytes.")
            let exemption = NoticeInventory.LicenseExemption(package: "example", path: path, reason: "Test fixture.",
                                                              sha256: fixtureDigest("Fixture bytes."))
            let files = NoticeUnreadableFiles(base: fileService, unreadable: root + "/example/" + path)
            XCTAssertThrowsError(try NoticeInventory(fileService: files, exemptions: [exemption]).checkSwiftPackages(
                resolved: root + "/resolved.json", checkouts: root,
                notices: parseNotices("[Example](https://github.com/vendor/example)"), credits: "Example license.")) { error in
                let message = (error as? NoticeInventory.MissingNotice)?.description ?? ""
                XCTAssertTrue(message.hasPrefix("Unreadable license candidate: example/" + path + ":"), "\(error)")
                XCTAssertEqual(files.readAttempts, [root + "/resolved.json", root + "/example/" + path])
            }
        }
    }

    func testRendererExportsItsLicenseBlocksAsJSON() throws {
        try withFixture { root in
            try fileService.writeFile(at: root + "/source.md", content: "```text\n```\n```text\nCopyright JSON.\n```\n")
            let result = try runCredits(arguments: ["--license-blocks", root + "/source.md"], fixtureRoot: root)
            XCTAssertEqual(result.status, 0, result.error)
            let blocks = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [[String: Any]])
            XCTAssertEqual(blocks.compactMap { $0["text"] as? String }, ["", "Copyright JSON."])
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

/// Audits temporary checkouts through real read probes, with a binary read failure
/// at one candidate. Mutations throw, so an audit can never write through this double.
private final class NoticeUnreadableFiles: FileServiceProtocol {
    private let base: FileService
    private let unreadable: String
    var readAttempts: [String] = []
    var textReadAttempts: [String] = []

    init(base: FileService, unreadable: String) {
        self.base = base
        self.unreadable = unreadable
    }

    func readData(at path: String) throws -> Data {
        readAttempts.append(path)
        if path == unreadable { throw CocoaError(.fileReadUnknown) }
        return try base.readData(at: path)
    }
    func readFile(at path: String) throws -> String {
        textReadAttempts.append(path)
        return try base.readFile(at: path)
    }
    func readRegularFileData(at path: String, maximumBytes: Int) throws -> Data {
        try base.readRegularFileData(at: path, maximumBytes: maximumBytes)
    }
    func writeFile(at path: String, content: String) throws { throw CocoaError(.featureUnsupported) }
    func writeData(at path: String, data: Data) throws { throw CocoaError(.featureUnsupported) }
    func writeExecutableFile(at path: String, content: String) throws { throw CocoaError(.featureUnsupported) }
    func copyFile(at sourcePath: String, to destinationPath: String) throws {
        throw CocoaError(.featureUnsupported)
    }
    func deleteFile(at path: String) throws { throw CocoaError(.featureUnsupported) }
    func fileExists(at path: String) -> Bool { base.fileExists(at: path) }
    func entryExistsWithoutFollowingLinks(at path: String) throws -> Bool { try base.entryExistsWithoutFollowingLinks(at: path) }
    func isExecutableFile(at path: String) -> Bool { base.isExecutableFile(at: path) }
    func isUserExecutableFile(at path: String) -> Bool { base.isUserExecutableFile(at: path) }
    func directoryExists(at path: String) -> Bool { base.directoryExists(at: path) }
    func createDirectory(at path: String) throws { throw CocoaError(.featureUnsupported) }
    func deleteDirectory(at path: String) throws { throw CocoaError(.featureUnsupported) }
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {
        throw CocoaError(.featureUnsupported)
    }
    func symlinkTarget(at path: String) throws -> String { try base.symlinkTarget(at: path) }
    func isSymlink(at path: String) -> Bool { base.isSymlink(at: path) }
    func isRegularFile(at path: String) -> Bool { base.isRegularFile(at: path) }
    func listDirectory(at path: String) throws -> [String] { try base.listDirectory(at: path) }
    func contentsHash(at path: String) throws -> String { try base.contentsHash(at: path) }
    func fileIdentity(at path: String, followingLinks: Bool) -> FileIdentity? {
        base.fileIdentity(at: path, followingLinks: followingLinks)
    }
    func realPath(at path: String) -> String { base.realPath(at: path) }
    func regularFileMetadata(at path: String) -> RegularFileMetadata? { base.regularFileMetadata(at: path) }
    func touchRegularFile(at path: String, date: Date) throws { throw CocoaError(.featureUnsupported) }
}
