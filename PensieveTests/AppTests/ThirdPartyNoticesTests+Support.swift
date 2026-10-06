import AppKit
import Darwin
import XCTest
@testable import Pensieve

/// Content cache shared by the canonical loader and isolated fixture-cache instances.
/// The loader reads the source before looking up a document, preserving read refusals.
final class NoticeFileCache {
    private var documents: [String: NoticeDocument] = [:]
    var count: Int { documents.count }

    func document(source: String, parse: () throws -> NoticeDocument) rethrows -> NoticeDocument {
        if let document = documents[source] { return document }
        let document = try parse()
        documents[source] = document
        return document
    }
}

extension ThirdPartyNoticesTests {
    private static let realNotices = NoticeFileCache()
    private static let fixtureNotices = NoticeFileCache()
    var canonicalNoticeCacheCount: Int { Self.realNotices.count }

    func readNotices() throws -> NoticeDocument {
        try loadNotices(at: sourceRoot + "/THIRD-PARTY-NOTICES.md")
    }

    /// Only the canonical notices fill the real content cache. Fixtures share the pure-source cache.
    /// Read files before reuse so changed or missing sources remain observable.
    func loadNotices(at path: String, cache: NoticeFileCache? = nil) throws -> NoticeDocument {
        let source = try fileService.readFile(at: path)
        if path == sourceRoot + "/THIRD-PARTY-NOTICES.md" {
            return try Self.realNotices.document(source: source) { try parseNoticeFile(source, at: path) }
        }
        guard let cache else { return try parseNotices(source) }
        return try cache.document(source: source) {
            try parseNoticeFile(source, at: path, fixtureRoot: URL(fileURLWithPath: path).deletingLastPathComponent().path)
        }
    }

    private func parseNoticeFile(_ source: String, at path: String, fixtureRoot: String? = nil) throws -> NoticeDocument {
        let result = try runCredits(arguments: ["--license-blocks", path], fixtureRoot: fixtureRoot)
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
        try Self.fixtureNotices.document(source: source) {
            var document: NoticeDocument?
            try withFixture { root in
                let path = root + "/source.md"
                try fileService.writeFile(at: path, content: source)
                document = try parseNoticeFile(source, at: path, fixtureRoot: root)
            }
            return try XCTUnwrap(document)
        }
    }

    func renderFixture(_ source: String) throws -> String {
        var rtf = ""
        try withFixture { root in
            try fileService.writeFile(at: root + "/source.md", content: source)
            let result = try runCredits(arguments: [root + "/source.md", root + "/Credits.rtf"], fixtureRoot: root)
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

    func runCredits(arguments: [String], fixtureRoot: String? = nil) throws -> CreditsResult {
        creditsRendererRuns += 1
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [sourceRoot + "/script/credits.py"] + arguments
        return try runCreditsProcess(process, fixtureRoot: fixtureRoot)
    }

    /// The child redirects stderr to a scratch file; Swift only drains the stdout pipe.
    /// FileService owns the fixture directory and reads the completed diagnostic file.
    func runCreditsProcess(_ process: Process, fixtureRoot: String? = nil,
                           readStdout: (Process, FileHandle) throws -> Data? = { _, handle in
                               try handle.readToEnd()
                           }) throws -> CreditsResult {
        if let fixtureRoot {
            return try runCreditsProcessInFixture(process, root: fixtureRoot, readStdout: readStdout)
        }
        var result: CreditsResult?
        try withFixture { root in
            result = try runCreditsProcessInFixture(process, root: root, readStdout: readStdout)
        }
        return try XCTUnwrap(result)
    }

    private func runCreditsProcessInFixture(_ configuration: Process, root: String,
                                            readStdout: (Process, FileHandle) throws -> Data?) throws -> CreditsResult {
        let errorPath = root + "/stderr.txt"
        let executable = try XCTUnwrap(configuration.executableURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #"error=$1; shift; exec "$@" 2>"$error""#,
                             "credits-output", errorPath, executable.path] + (configuration.arguments ?? [])
        process.environment = configuration.environment
        process.currentDirectoryURL = configuration.currentDirectoryURL
        process.standardInput = configuration.standardInput
        process.qualityOfService = configuration.qualityOfService
        let stdout = Pipe()
        process.standardOutput = stdout
        defer { try? stdout.fileHandleForReading.close() }
        try process.run()
        let output: Data
        do {
            output = try readStdout(process, stdout.fileHandleForReading) ?? Data()
        } catch {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        let diagnostic: String
        do {
            diagnostic = decodeCreditsOutput(try fileService.readData(at: errorPath))
        } catch {
            diagnostic = "Credits stderr unavailable: \(error.localizedDescription)"
        }
        return CreditsResult(status: process.terminationStatus,
                             output: decodeCreditsOutput(output), error: diagnostic)
    }

    private func decodeCreditsOutput(_ data: Data) -> String {
        var text = "", decoder = UTF8(), bytes = data.makeIterator()
        while true {
            switch decoder.decode(&bytes) {
            case .scalarValue(let scalar): text.unicodeScalars.append(scalar)
            case .error: text.unicodeScalars.append("\u{FFFD}")
            case .emptyInput: return text
            }
        }
    }
}
