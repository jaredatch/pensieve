import XCTest
@testable import Pensieve

final class PathSyntaxGuardTests: XCTestCase {
    private var repository: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent() }

    func testAppAndDaemonPathChecksUseScalarSyntax() throws {
        let result = try runGuard(root: repository)
        XCTAssertEqual(result.status, 0, result.output)
    }

    func testNewGraphemeChecksFailAndNameAppOrDaemonFile() throws {
        let root = TestTemporaryDirectory.url.appendingPathComponent("PathGuard-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rejected = [
            "path.hasPrefix(\"/\")", "path.hasSuffix(\"/\")", "path.contains(\"/\")", "path.hasPrefix(\"~\")",
            "path.hasPrefix(root + \"/\")", "path.hasSuffix(\"/SKILL.md\")",
            "path . hasPrefix /* nested /* c */ c */ (\nroot + #\"/\"#)",
            "path.contains(\"\\u{2F}\")", "path.hasPrefix(\"\\(root)/\")",
            "path.hasPrefix(\"\"\"\n/\n\"\"\")",
            "\"value \\(path.hasPrefix(\"/\"))\"",
            "{ let prefix = root + \"/\"; return path.hasPrefix(prefix) }()"
        ]
        for folder in ["Pensieve", "PensieveDaemon"] {
            let file = root.appendingPathComponent(folder + "/NewOwner.swift")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            for expression in rejected {
                try ("func classify() {\nlet x = " + expression + "\n}\n").write(to: file, atomically: true, encoding: .utf8)
                let result = try runGuard(root: root)
                XCTAssertEqual(result.status, 1, expression)
                XCTAssertTrue(result.output.contains(folder + "/NewOwner.swift:2:"), result.output)
            }
            let permitted = """
                func classify() {
                    // path.hasPrefix("/")
                    /* path.contains("~") */
                    let text = "path.hasPrefix(\\\"/\\\")"
                    let accepted = PathSyntax.hasPrefix(path, root + "/")
                    let byte = bytes.contains(UInt8(ascii: "/"))
                    let collection = roots.contains(where: { PathSyntax.hasPrefix(path, $0 + "/") })
                }
                """
            try permitted.write(to: file, atomically: true, encoding: .utf8)
            let result = try runGuard(root: root)
            XCTAssertEqual(result.status, 0, result.output)
            try FileManager.default.removeItem(at: file)
        }
        let urlFile = root.appendingPathComponent("Pensieve/Services/SkillInstallURL.swift")
        try FileManager.default.createDirectory(at: urlFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "func newFilesystemCheck() { path.hasPrefix(\"/\") }".write(to: urlFile, atomically: true, encoding: .utf8)
        let result = try runGuard(root: root)
        XCTAssertEqual(result.status, 1, "A URL file isn't exempt as a whole")
        XCTAssertTrue(result.output.contains("SkillInstallURL.swift:1:"), result.output)
    }

    private func runGuard(root: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", repository.appendingPathComponent("script/check-path-syntax.py").path,
                             "--root", root.path]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "Invalid guard output")
    }
}
