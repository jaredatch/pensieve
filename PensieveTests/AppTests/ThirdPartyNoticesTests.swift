import AppKit
import XCTest
@testable import Pensieve

@MainActor
final class ThirdPartyNoticesTests: XCTestCase {
    let fileService = FileService()
    var sourceRoot: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path
    }
    var inventory: NoticeInventory { NoticeInventory(fileService: fileService) }

    func testBundledCreditsCoverSwiftPackagesAndVendoredLicenseFiles() throws {
        let pins = try inventory.checkSwiftPackages(
            resolved: sourceRoot + "/Pensieve.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
            checkouts: inventory.checkouts(for: Bundle.main.bundleURL),
            notices: readNotices(),
            credits: bundledCredits()
        )
        try LibYAMLNoticeAudit.checkVendorVersion(pins: pins)
    }

    func testBundledCreditsCoverEditorPackages() throws {
        try inventory.checkEditorPackages(
            lockfile: sourceRoot + "/webeditor/package-lock.json",
            notices: readNotices(),
            credits: bundledCredits()
        )
    }

    func testBundledCreditsContainEverySourceLicenseBlock() throws {
        let notices = try readNotices()
        let credits = NoticeInventory.normalized(try bundledCredits())
        XCTAssertGreaterThan(notices.licenseBlocks.count, 10)
        for block in notices.licenseBlocks {
            let license = NoticeInventory.normalized(block.text)
            XCTAssertTrue(credits.contains(license), "Credits omitted license: \(license.prefix(160))")
        }
    }

    func testLibYAMLNoticeIsComplete() throws {
        let license = try XCTUnwrap(readNotices().license(inSection: "### libYAML"))
        XCTAssertEqual(LibYAMLNoticeAudit.noticeDigest(license), LibYAMLNoticeAudit.digest)
        XCTAssertTrue(try bundledCredits().contains("libYAML"))
    }

    func testNewSwiftPackageWithoutNoticeIsNamed() throws {
        try withFixture { root in
            try fileService.writeFile(at: root + "/resolved.json", content: "{\"pins\":[{\"identity\":\"new-library\"}]}")
            assertMissing("Missing notice for Swift package new-library") {
                try inventory.checkSwiftPackages(resolved: root + "/resolved.json", checkouts: root,
                                                 notices: parseNotices(""), credits: "")
            }
        }
    }

    func testNewEditorPackageWithoutNoticeIsNamed() throws {
        try withFixture { root in
            try writeEditorLock(root: root, dev: false)
            assertMissing("Missing notice for editor package @vendor/new-library") {
                try inventory.checkEditorPackages(lockfile: root + "/lock.json", notices: parseNotices(""), credits: "")
            }
        }
    }

    func testDevOnlyEditorPackageNeedsNoNotice() throws {
        try withFixture { root in
            try writeEditorLock(root: root, dev: true)
            try inventory.checkEditorPackages(lockfile: root + "/lock.json", notices: parseNotices(""), credits: "")
        }
    }

    func testNewVendoredLicenseWithoutNoticeIsNamed() throws {
        try withSwiftFixture { root in
            let vendor = root + "/example/Vendor/NewLibrary"
            try fileService.createDirectory(at: vendor)
            try fileService.writeFile(at: vendor + "/License.txt", content: "Copyright New Library. Unique terms.")
            assertMissing("Missing bundled license: example/Vendor/NewLibrary/License.txt") {
                try checkSwiftFixture(root: root, credits: "Example license.")
            }
        }
    }

    func testPartialVendoredLicenseIsRefused() throws {
        try withSwiftFixture { root in
            assertMissing("Missing bundled license: example/LICENSE") {
                try checkSwiftFixture(root: root, credits: "Example")
            }
        }
    }

    func testCompleteVendoredLicenseIsAccepted() throws {
        try withSwiftFixture { root in
            try checkSwiftFixture(root: root, credits: "Example\n license.")
        }
    }

    func testRendererRoundTripsUnicodeAndRTFSyntax() throws {
        let notice = "Copyright Ingy döt Net. {braces} \\backslash 日本語 🐈"
        let rtf = try renderFixture("# Notices\n```text\n\(notice)\n```\n")
        let rendered = try decodeCredits(Data(rtf.utf8))
        XCTAssertEqual(rendered.string.trimmingCharacters(in: .whitespacesAndNewlines), "Notices\n" + notice)
    }

    private func bundledCredits() throws -> String {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "Credits", ofType: "rtf"), "App is missing Credits.rtf")
        let data = try fileService.readData(at: path)
        return try decodeCredits(data).string
    }

    func assertMissing(_ expected: String, operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), expected) { error in
            XCTAssertEqual((error as? NoticeInventory.MissingNotice)?.description, expected)
        }
    }

    func withFixture(_ operation: (String) throws -> Void) throws {
        let root = NSTemporaryDirectory() + "notices-" + UUID().uuidString
        try fileService.createDirectory(at: root)
        defer { try? fileService.deleteDirectory(at: root) }
        try operation(root)
    }

    func withSwiftFixture(_ operation: (String) throws -> Void) throws {
        try withFixture { root in
            try fileService.createDirectory(at: root + "/example")
            try fileService.writeFile(at: root + "/example/LICENSE", content: "Example license.")
            try fileService.writeFile(at: root + "/resolved.json", content: "{\"pins\":[{\"identity\":\"example\"}]}")
            try operation(root)
        }
    }

    func checkSwiftFixture(root: String, credits: String) throws {
        try inventory.checkSwiftPackages(resolved: root + "/resolved.json", checkouts: root,
                                         notices: parseNotices("[Example](https://github.com/vendor/example)"),
                                         credits: credits)
    }

    private func writeEditorLock(root: String, dev: Bool) throws {
        try fileService.writeFile(at: root + "/lock.json", content: """
        {"packages":{"":{"name":"editor"},"node_modules/@vendor/new-library":{"dev":\(dev),"license":"MIT"}}}
        """)
    }
}
