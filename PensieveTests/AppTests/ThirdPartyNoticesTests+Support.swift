import AppKit
import XCTest
@testable import Pensieve

extension ThirdPartyNoticesTests {
    private static var noticesByPath: [String: NoticeDocument] = [:]
    private static var fixtureNotices: [String: NoticeDocument] = [:]

    func readNotices() throws -> NoticeDocument {
        try loadNotices(at: sourceRoot + "/THIRD-PARTY-NOTICES.md")
    }

    func loadNotices(at path: String) throws -> NoticeDocument {
        if let cached = Self.noticesByPath[path] { return cached }
        let source = try fileService.readFile(at: path)
        let result = try runCredits(arguments: ["--license-blocks", path])
        XCTAssertEqual(result.status, 0, result.error)
        let blocks = try JSONDecoder().decode([NoticeDocument.LicenseBlock].self, from: Data(result.output.utf8))
        let document = NoticeDocument(source, licenseBlocks: blocks)
        Self.noticesByPath[path] = document
        return document
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
            document = try loadNotices(at: path)
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

    func runCredits(arguments: [String], pythonVersion: String? = nil, code: String? = nil) throws -> CreditsResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let script = sourceRoot + "/script/credits.py"
        process.arguments = [script] + arguments
        if let pythonVersion {
            process.arguments = ["-c", "import runpy,sys; sys.version_info=(" + pythonVersion + "); "
                                 + "sys.argv=sys.argv[1:]; runpy.run_path(sys.argv[0],run_name='__main__')", script] + arguments
        }
        if let code { process.arguments = ["-c", code] + arguments }
        return try runCreditsProcess(process)
    }

    func runCreditsProcess(_ process: Process) throws -> CreditsResult {
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let drain = CreditsPipeDrain(error.fileHandleForReading)
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = drain.join()
        process.waitUntilExit()
        return CreditsResult(status: process.terminationStatus, output: String(data: stdout, encoding: .utf8) ?? "",
                             error: String(data: stderr, encoding: .utf8) ?? "")
    }
}

/// A dedicated reader drains stderr while the caller drains stdout. Only pipe I/O;
/// the process and both readers finish before the helper returns.
private final class CreditsPipeDrain {
    private let condition = NSCondition()
    private var data: Data?

    init(_ handle: FileHandle) {
        let thread = Thread {
            let data = handle.readDataToEndOfFile()
            self.condition.lock()
            self.data = data
            self.condition.signal()
            self.condition.unlock()
        }
        thread.name = "Pensieve notices stderr drain"
        thread.qualityOfService = Thread.current.qualityOfService
        thread.start()
    }

    func join() -> Data {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let data { return data }
            condition.wait()
        }
    }
}
