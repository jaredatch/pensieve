import AppKit
import XCTest
@testable import Pensieve

extension ThirdPartyNoticesTests {
    private static var cachedNotices: (source: String, document: NoticeDocument)?

    func readNotices() throws -> NoticeDocument {
        try loadNotices(at: sourceRoot + "/THIRD-PARTY-NOTICES.md")
    }

    /// Only the real notices loader caches. Read content every time; fixture parsing is uncached.
    func loadNotices(at path: String) throws -> NoticeDocument {
        let source = try fileService.readFile(at: path)
        if let cached = Self.cachedNotices, cached.source == source { return cached.document }
        let document = try parseNoticeFile(source, at: path)
        Self.cachedNotices = (source, document)
        return document
    }

    private func parseNoticeFile(_ source: String, at path: String) throws -> NoticeDocument {
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
        var document: NoticeDocument?
        try withFixture { root in
            let path = root + "/source.md"
            try fileService.writeFile(at: path, content: source)
            document = try parseNoticeFile(source, at: path)
        }
        return try XCTUnwrap(document)
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

    func runCreditsProcess(_ process: Process, io: GitService.ProcessIO = GitService.ProcessIO()) throws -> CreditsResult {
        process.standardOutput = io.stdout
        process.standardError = io.stderr
        try process.run()
        let cleanup = GitService.ReadFailureCleanup(process)
        let drain = GitService.PipeDrain(io.stderr.fileHandleForReading, read: io.read, onFailure: cleanup.stop)
        let stdout = Result { try io.read(io.stdout.fileHandleForReading) ?? Data() }
        if case .failure = stdout { cleanup.stop() }
        let stderr = drain.join()
        process.waitUntilExit()
        return try CreditsResult(status: process.terminationStatus,
                                 output: String(data: stdout.get(), encoding: .utf8) ?? "",
                                 error: String(data: stderr.get(), encoding: .utf8) ?? "")
    }
}
