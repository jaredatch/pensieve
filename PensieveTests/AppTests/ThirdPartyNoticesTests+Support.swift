import AppKit
import XCTest
@testable import Pensieve

extension ThirdPartyNoticesTests {
    func readNotices() throws -> NoticeDocument {
        try NoticeDocument(fileService.readFile(at: sourceRoot + "/THIRD-PARTY-NOTICES.md"))
    }

    func decodeCredits(_ data: Data) throws -> NSAttributedString {
        try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                               documentAttributes: nil)
    }

    func renderFixture(_ source: String, portable: Bool = false) throws -> String {
        var rtf = ""
        try withFixture { root in
            try fileService.writeFile(at: root + "/source.md", content: source)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [sourceRoot + "/script/credits.py", root + "/source.md", root + "/Credits.rtf"]
            if portable {
                let harness = """
                import runpy, sys
                from pathlib import Path
                class OldLine(str):
                    def removesuffix(self, suffix):
                        raise AttributeError("str.removesuffix is unavailable before Python 3.9")
                class OldText(str):
                    def split(self, separator):
                        return [OldLine(line) for line in super().split(separator)]
                renderer = runpy.run_path(sys.argv[1])
                source = Path(sys.argv[2]).read_bytes().decode("utf-8")
                Path(sys.argv[3]).write_text(renderer["render"](OldText(source)), encoding="ascii")
                """
                process.arguments = ["-c", harness] + (process.arguments ?? [])
            }
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            rtf = try fileService.readFile(at: root + "/Credits.rtf")
        }
        return rtf
    }
}
