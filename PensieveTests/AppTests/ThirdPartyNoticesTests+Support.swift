import AppKit
import XCTest
@testable import Pensieve

extension ThirdPartyNoticesTests {
    func readNotices() throws -> NoticeDocument {
        try parseNotices(fileService.readFile(at: sourceRoot + "/THIRD-PARTY-NOTICES.md"))
    }

    func decodeCredits(_ data: Data) throws -> NSAttributedString {
        try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                               documentAttributes: nil)
    }

    func parseNotices(_ source: String) throws -> NoticeDocument {
        var blocks: [NoticeDocument.LicenseBlock] = []
        try withFixture { root in
            try fileService.writeFile(at: root + "/source.md", content: source)
            let result = try runCredits(arguments: ["--license-blocks", root + "/source.md"])
            XCTAssertEqual(result.status, 0, result.error)
            blocks = try JSONDecoder().decode([NoticeDocument.LicenseBlock].self, from: Data(result.output.utf8))
        }
        return NoticeDocument(source, licenseBlocks: blocks)
    }

    func renderFixture(_ source: String) throws -> String {
        var rtf = ""
        try withFixture { root in
            try fileService.writeFile(at: root + "/source.md", content: source)
            let result = try runCredits(arguments: [root + "/source.md", root + "/Credits.rtf"])
            XCTAssertEqual(result.status, 0, result.error)
            rtf = try fileService.readFile(at: root + "/Credits.rtf")
        }
        return rtf
    }

    struct CreditsResult {
        let status: Int32
        let output: String
        let error: String
    }

    func runCredits(arguments: [String], oldVersion: Bool = false) throws -> CreditsResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let script = sourceRoot + "/script/credits.py"
        process.arguments = [script] + arguments
        if oldVersion {
            process.arguments = ["-c", "import runpy,sys; sys.version_info=(3,8,0); "
                                 + "sys.argv=sys.argv[1:]; runpy.run_path(sys.argv[0],run_name='__main__')", script] + arguments
        }
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CreditsResult(status: process.terminationStatus, output: String(data: stdout, encoding: .utf8) ?? "",
                             error: String(data: stderr, encoding: .utf8) ?? "")
    }
}
