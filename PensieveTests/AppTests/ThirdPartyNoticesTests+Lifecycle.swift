import CryptoKit
import XCTest
@testable import Pensieve

extension ThirdPartyNoticesTests {
    func testRendererAcceptsItsActualPythonFloor() throws {
        try withFixture { root in
            try fileService.writeFile(at: root + "/source.md", content: "# Notices\n")
            let result = try runCredits(arguments: [root + "/source.md", root + "/Credits.rtf"], pythonVersion: "3,6,0")
            XCTAssertEqual(result.status, 0, result.error)
            XCTAssertTrue(fileService.fileExists(at: root + "/Credits.rtf"))
        }
    }

    func testBuildPhaseIgnoresPythonOnPATH() throws {
        let data = try fileService.readData(at: sourceRoot + "/Pensieve.xcodeproj/project.pbxproj")
        let project = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let objects = try XCTUnwrap(project["objects"] as? [String: [String: Any]])
        let phase = try XCTUnwrap(objects.values.first { $0["name"] as? String == "Generate About credits" })
        let command = try XCTUnwrap(phase["shellScript"] as? String)
        try withFixture { root in
            try fileService.createDirectory(at: root + "/script")
            try fileService.writeFile(at: root + "/script/credits.py",
                                      content: fileService.readFile(at: sourceRoot + "/script/credits.py"))
            try fileService.writeFile(at: root + "/THIRD-PARTY-NOTICES.md", content: "# Fixture\n")
            try fileService.createDirectory(at: root + "/bin")
            try fileService.writeExecutableFile(at: root + "/bin/python3", content: "#!/bin/sh\nexit 91\n")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", command]
            process.environment = ["PATH": root + "/bin:/usr/bin:/bin", "SRCROOT": root,
                                   "TARGET_BUILD_DIR": root, "UNLOCALIZED_RESOURCES_FOLDER_PATH": "Resources"]
            let result = try runCreditsProcess(process)
            XCTAssertEqual(result.status, 0, result.error)
            XCTAssertTrue(fileService.fileExists(at: root + "/Resources/Credits.rtf"))
        }
    }

    func testRendererDrainsLargeStderrBeforeStdout() throws {
        let code = "import os,signal,sys; signal.signal(signal.SIGALRM,lambda *args:os._exit(72)); signal.alarm(3); "
            + "sys.stderr.write('E'*262144); sys.stderr.flush(); sys.stdout.write('DONE'); sys.stdout.flush()"
        let result = try runCredits(arguments: [], code: code)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "DONE")
        XCTAssertEqual(result.error.count, 262144)
    }

    func testRemovingStaleLibYAMLNoticeClearsFailure() throws {
        try withFixture { root in
            try fileService.writeFile(at: root + "/resolved.json", content: "{\"pins\":[]}")
            let stale = "### libYAML\n```text\nCopyright Old vendor.\n```\n"
            assertMissing("Stale libYAML notice: Yams is no longer resolved; remove its notice or audit the new vendor") {
                try auditLifecycleFixture(root: root, notices: stale)
            }
            XCTAssertNoThrow(try auditLifecycleFixture(root: root, notices: ""))
        }
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

    func testLinkedYamsStillRequiresLibYAMLSection() throws {
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

    func testNoticePathIsParsedOncePerRun() throws {
        try withFixture { root in
            let path = root + "/notices.md"
            try fileService.writeFile(at: path, content: "```text\nCopyright Cached.\n```\n")
            let original = try loadNotices(at: path)
            try fileService.deleteFile(at: path)
            XCTAssertEqual(try loadNotices(at: path).licenseBlocks.map(\.text), original.licenseBlocks.map(\.text))
        }
    }

    func fixtureDigest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func checkExemptionFixture(root: String, exemptions: [NoticeInventory.LicenseExemption]) throws {
        try NoticeInventory(fileService: fileService, exemptions: exemptions).checkSwiftPackages(
            resolved: root + "/resolved.json", checkouts: root,
            notices: parseNotices("[Example](https://github.com/vendor/example)"), credits: "Example license.")
    }

    private func auditLifecycleFixture(root: String, notices: String) throws {
        try inventory.checkSwiftPackages(resolved: root + "/resolved.json", checkouts: root,
                                                   notices: parseNotices(notices), credits: "")
    }
}
