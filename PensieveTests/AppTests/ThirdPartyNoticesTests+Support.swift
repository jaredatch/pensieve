import AppKit
import XCTest
@testable import Pensieve

extension ThirdPartyNoticesTests {
    private static var realNotices: [String: NoticeDocument] = [:]
    private static var fixtureNotices: [String: NoticeDocument] = [:]

    func readNotices() throws -> NoticeDocument {
        try loadNotices(at: sourceRoot + "/THIRD-PARTY-NOTICES.md")
    }

    /// Real documents and pure fixture sources have separate content caches. Read files before reuse.
    func loadNotices(at path: String) throws -> NoticeDocument {
        let source = try fileService.readFile(at: path)
        if let cached = Self.realNotices[source] { return cached }
        let document = try parseNoticeFile(source, at: path)
        Self.realNotices[source] = document
        return document
    }

    private func parseNoticeFile(_ source: String, at path: String) throws -> NoticeDocument {
        noticeParseCount += 1
        let result = try runCredits(arguments: ["--license-blocks", path])
        XCTAssertEqual(result.status, 0, result.error)
        let blocks = try JSONDecoder().decode([NoticeDocument.LicenseBlock].self, from: Data(result.output.utf8))
        return NoticeDocument(source, licenseBlocks: blocks)
    }

    func decodeCredits(_ data: Data) throws -> NSAttributedString {
        try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                               documentAttributes: nil)
    }

    func parseNotices(_ source: String) throws -> NoticeDocument {
        if let cached = Self.fixtureNotices[source] { return cached }
        var document: NoticeDocument?
        try withFixture { root in
            let path = root + "/source.md"
            try fileService.writeFile(at: path, content: source)
            document = try parseNoticeFile(source, at: path)
        }
        let parsed = try XCTUnwrap(document)
        Self.fixtureNotices[source] = parsed
        return parsed
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

    func runCredits(arguments: [String]) throws -> CreditsResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [sourceRoot + "/script/credits.py"] + arguments
        return try runCreditsProcess(process)
    }

    func runCreditsProcess(_ process: Process, stdout: Pipe = Pipe(), stderr: Pipe = Pipe(),
                           read: @escaping (FileHandle) throws -> Data? = { try $0.readToEnd() }) throws -> CreditsResult {
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let (output, error) = GitService.readProcessOutput(process: process, stdout: stdout, stderr: stderr, read: read)
        return try CreditsResult(status: process.terminationStatus,
                                 output: String(data: output.get(), encoding: .utf8) ?? "",
                                 error: String(data: error.get(), encoding: .utf8) ?? "")
    }
}
