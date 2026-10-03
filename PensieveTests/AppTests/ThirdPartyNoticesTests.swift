import AppKit
import CryptoKit
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
        try inventory.checkSwiftPackages(
            resolved: sourceRoot + "/Pensieve.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
            checkouts: sourceRoot + "/DerivedData/SourcePackages/checkouts",
            notices: fileService.readFile(at: sourceRoot + "/THIRD-PARTY-NOTICES.md"),
            credits: bundledCredits()
        )
    }

    func testBundledCreditsCoverEditorPackages() throws {
        try inventory.checkEditorPackages(
            lockfile: sourceRoot + "/webeditor/package-lock.json",
            notices: fileService.readFile(at: sourceRoot + "/THIRD-PARTY-NOTICES.md"),
            credits: bundledCredits()
        )
    }

    func testBundledCreditsContainEverySourceLicenseBlock() throws {
        let notices = try fileService.readFile(at: sourceRoot + "/THIRD-PARTY-NOTICES.md")
        let credits = NoticeInventory.normalized(try bundledCredits())
        let expression = try NSRegularExpression(pattern: "```text\\n(.*?)\\n```", options: .dotMatchesLineSeparators)
        let matches = expression.matches(in: notices, range: NSRange(notices.startIndex..., in: notices))
        XCTAssertGreaterThan(matches.count, 10)
        for match in matches {
            let range = try XCTUnwrap(Range(match.range(at: 1), in: notices))
            let license = NoticeInventory.normalized(String(notices[range]))
            XCTAssertTrue(credits.contains(license), "Credits omitted license: \(license.prefix(160))")
        }
    }

    func testLibYAMLNoticeIsComplete() throws {
        let notices = try fileService.readFile(at: sourceRoot + "/THIRD-PARTY-NOTICES.md")
        let section = try XCTUnwrap(notices.range(of: "### libYAML\n"))
        let suffix = notices[section.upperBound...]
        let start = try XCTUnwrap(suffix.range(of: "```text\n"))
        let end = try XCTUnwrap(suffix[start.upperBound...].range(of: "\n```"))
        let license = NoticeInventory.normalized(String(suffix[start.upperBound..<end.lowerBound]))
        // Digest of yaml/libyaml 0.2.5's complete License, normalized only for whitespace.
        let digest = SHA256.hash(data: Data(license.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "6cc0c393c5cb002fce678ab4f5e7642c58fdb32f9e7ee27ada2ef111df5ac021")
        XCTAssertTrue(try bundledCredits().contains("libYAML"))
    }

    func testNewSwiftPackageWithoutNoticeIsNamed() throws {
        try withFixture { root in
            try fileService.writeFile(at: root + "/resolved.json", content: "{\"pins\":[{\"identity\":\"new-library\"}]}")
            assertMissing("Missing notice for Swift package new-library") {
                try inventory.checkSwiftPackages(resolved: root + "/resolved.json", checkouts: root,
                                                 notices: "", credits: "")
            }
        }
    }

    func testNewEditorPackageWithoutNoticeIsNamed() throws {
        try withFixture { root in
            try writeEditorLock(root: root, dev: false)
            assertMissing("Missing notice for editor package @vendor/new-library") {
                try inventory.checkEditorPackages(lockfile: root + "/lock.json", notices: "", credits: "")
            }
        }
    }

    func testDevOnlyEditorPackageNeedsNoNotice() throws {
        try withFixture { root in
            try writeEditorLock(root: root, dev: true)
            try inventory.checkEditorPackages(lockfile: root + "/lock.json", notices: "", credits: "")
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
        try withFixture { root in
            let notice = "Copyright Ingy döt Net. {braces} \\backslash 日本語 🐈"
            try fileService.writeFile(at: root + "/notices.md", content: "# Notices\n```text\n\(notice)\n```\n")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [sourceRoot + "/script/credits.py", root + "/notices.md", root + "/Credits.rtf"]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let data = try fileService.readData(at: root + "/Credits.rtf")
            let rendered = try NSAttributedString(
                data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil
            )
            XCTAssertEqual(rendered.string.trimmingCharacters(in: .whitespacesAndNewlines), "Notices\n" + notice)
        }
    }

    private func bundledCredits() throws -> String {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "Credits", ofType: "rtf"), "App is missing Credits.rtf")
        let data = try fileService.readData(at: path)
        return try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                      documentAttributes: nil).string
    }

    func assertMissing(_ expected: String, operation: () throws -> Void) {
        XCTAssertThrowsError(try operation()) { error in
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
                                         notices: "[Example](https://github.com/vendor/example)", credits: credits)
    }

    private func writeEditorLock(root: String, dev: Bool) throws {
        try fileService.writeFile(at: root + "/lock.json", content: """
        {"packages":{"":{"name":"editor"},"node_modules/@vendor/new-library":{"dev":\(dev),"license":"MIT"}}}
        """)
    }
}
