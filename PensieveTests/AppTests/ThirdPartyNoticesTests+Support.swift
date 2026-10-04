import AppKit
import XCTest
@testable import Pensieve

extension ThirdPartyNoticesTests {
    private static var realNotices: [String: NoticeDocument] = [:]
    private static var fixtureNotices: [String: NoticeDocument] = [:]

    func readNotices() throws -> NoticeDocument {
        try loadNotices(at: sourceRoot + "/THIRD-PARTY-NOTICES.md")
    }

    /// Only the canonical notices fill the real content cache. Fixtures share the pure-source cache.
    /// Read files before reuse so changed or missing sources remain observable.
    func loadNotices(at path: String, canonicalPath: String? = nil) throws -> NoticeDocument {
        let source = try fileService.readFile(at: path)
        guard path == (canonicalPath ?? sourceRoot + "/THIRD-PARTY-NOTICES.md") else {
            return try parseNotices(source)
        }
        if let cached = Self.realNotices[source] { return cached }
        let document = try parseNoticeFile(source, at: path)
        Self.realNotices[source] = document
        return document
    }

    private func parseNoticeFile(_ source: String, at path: String) throws -> NoticeDocument {
        let result = try runCredits(arguments: ["--license-blocks", path])
        XCTAssertEqual(result.status, 0, result.error)
        let blocks = try JSONDecoder().decode([NoticeDocument.LicenseBlock].self, from: Data(result.output.utf8))
        return NoticeDocument(source, licenseBlocks: blocks)
    }

    func hasRenderedLibYAMLSection(_ credits: NSAttributedString, license: String) -> Bool {
        var headings: [(text: String, range: NSRange)] = []
        let text = credits.string
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byLines) { line, range, _, _ in
            let bounds = NSRange(range, in: text)
            if let line, !line.isEmpty,
               let font = credits.attribute(.font, at: bounds.location, effectiveRange: nil) as? NSFont,
               NSFontManager.shared.traits(of: font).contains(.boldFontMask) {
                headings.append((line, bounds))
            }
        }
        guard let index = headings.firstIndex(where: { $0.text == "libYAML" }) else { return false }
        let start = NSMaxRange(headings[index].range)
        let end = headings.dropFirst(index + 1).first?.range.location ?? credits.length
        let body = (credits.string as NSString).substring(with: NSRange(location: start, length: end - start))
        return NoticeInventory.normalized(body).contains(NoticeInventory.normalized(license))
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

    /// The child redirects stderr to a scratch file; Swift only drains the stdout pipe.
    /// FileService owns the fixture directory and reads the completed diagnostic file.
    func runCreditsProcess(_ process: Process) throws -> CreditsResult {
        var result: CreditsResult?
        try withFixture { root in
            let errorPath = root + "/stderr.txt"
            let executable = try XCTUnwrap(process.executableURL)
            let arguments = process.arguments ?? []
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", #"error=$1; shift; exec "$@" 2>"$error""#,
                                 "credits-output", errorPath, executable.path] + arguments
            let stdout = Pipe()
            process.standardOutput = stdout
            try process.run()
            let output = try stdout.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            result = CreditsResult(status: process.terminationStatus,
                                   output: String(data: output, encoding: .utf8) ?? "",
                                   error: try fileService.readFile(at: errorPath))
        }
        return try XCTUnwrap(result)
    }
}
