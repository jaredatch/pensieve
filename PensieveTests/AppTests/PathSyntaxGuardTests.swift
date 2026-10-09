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
        for folder in ["Pensieve", "PensieveDaemon"] {
            let file = root.appendingPathComponent(folder + "/NewOwner.swift")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            for (expression, line) in rejectedProbes {
                try ("func classify() {\nlet x = " + expression + "\n}\n").write(to: file, atomically: true, encoding: .utf8)
                let result = try runGuard(root: root)
                XCTAssertEqual(result.status, 1, expression)
                XCTAssertTrue(result.output.contains(folder + "/NewOwner.swift:\(line):"), result.output)
            }
            try permittedProbes.write(to: file, atomically: true, encoding: .utf8)
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
        try FileManager.default.removeItem(at: urlFile)
        try assertInitializerExemptionIsScoped(root: root)
        try assertExemptOwnersSurviveCallsAndClosureParameters(root: root)
    }

    private var rejectedProbes: [(String, Int)] {
        let expressions = [
            "path.hasPrefix(\"/\")", "path.hasSuffix(\"/\")", "path.contains(\"/\")", "path.hasPrefix(\"~\")",
            "path.split(separator: \"/\")", "path.firstIndex(of: \"/\")", "path.starts(with: \"/\")",
            "path.first == \"/\"", "path.last == \"/\"",
            "path.last != \"/\"", "path.first == Character(\"/\")",
            "\"/\" == path.first", "path.first == (\"/\")",
            "path.hasPrefix(root + \"/\")", "path.hasSuffix(\"/SKILL.md\")",
            "path . hasPrefix /* nested /* c */ c */ (\nroot + #\"/\"#)",
            "path.contains(\"\\u{2F}\")", "path.hasPrefix(\"\\(root)/\")",
            "path.hasPrefix(\"\"\"\n/\n\"\"\")",
            "\"value \\(path.hasPrefix(\"/\"))\"",
            "{ let prefix = root + \"/\"; return path.hasPrefix(prefix) }()"
        ]
        let preceding = ["path.utf8", "path.unicodeScalars", "path.utf16", "PathSyntax.isAbsolute"]
        return expressions.map { ($0, 2) }
            + preceding.map { ($0 + "\nif path.hasPrefix(\"/\") {}", 3) }
            + [("path.utf8; if path.hasPrefix(\"/\") {}", 2), ("path\n.hasPrefix(\"/\")", 3)]
    }

    private var permittedProbes: String {
        """
                func classify() {
                    // path.hasPrefix("/")
                    /* path.contains("~") */
                    let text = "path.hasPrefix(\\\"/\\\")"
                    let accepted = PathSyntax.hasPrefix(path, root + "/")
                    let byte = bytes.contains(UInt8(ascii: "/"))
                    let byteIndex = bytes.firstIndex(of: UInt8(ascii: "/"))
                    let scalar = path.unicodeScalars.first == "/"
                    let scalarParts = path.unicodeScalars.split(separator: "/")
                    let collection = roots.contains(where: { PathSyntax.hasPrefix(path, $0 + "/") })
                    let bytes = path
                        .utf8
                        .contains(UInt8(ascii: "/"))
                    let scalarChain = path
                        .unicodeScalars
                        .first == "/"
                    let helperChain = PathSyntax
                        .hasPrefix(path, root + "/")
                }
                """
    }

    private func assertInitializerExemptionIsScoped(root: URL) throws {
        let updates = root.appendingPathComponent("Pensieve/Services/SkillInstallService+Updates.swift")
        let initializers = """
            struct PinnedSkillUpdate {
                init(skill: Skill) { repo.hasSuffix("/") }
                init(path: String) { path.hasPrefix("/") }
            }
            """
        try initializers.write(to: updates, atomically: true, encoding: .utf8)
        let scoped = try runGuard(root: root)
        XCTAssertEqual(scoped.status, 1, "Only the stored-URL initializer is exempt")
        XCTAssertTrue(scoped.output.contains("SkillInstallService+Updates.swift:3:"), scoped.output)
        XCTAssertFalse(scoped.output.contains("SkillInstallService+Updates.swift:2:"), scoped.output)
        try FileManager.default.removeItem(at: updates)
    }

    private func assertExemptOwnersSurviveCallsAndClosureParameters(root: URL) throws {
        let identity = root.appendingPathComponent("Pensieve/Services/ProjectIdentityService.swift")
        let source = """
            struct ProjectIdentityService {
                static func normalizeRemoteURL(_ remote: String) -> String {
                    let url = URL.init(string: remote)
                    if remote.hasSuffix("/") { return remote }
                    return remote
                }
            }
            """
        try source.write(to: identity, atomically: true, encoding: .utf8)
        let call = try runGuard(root: root)
        XCTAssertEqual(call.status, 0, call.output)
        let git = root.appendingPathComponent("Pensieve/Services/GitService.swift")
        let closure = """
            struct GitService {
                func remoteDefaultBranch(remote value: String = { (factory: () -> String) -> String in factory() }({ "origin" }),
                                         credential token: GitCredential?) {
                    if value.hasPrefix("/") { return }
                }
            }
            """
        try closure.write(to: git, atomically: true, encoding: .utf8)
        let parameter = try runGuard(root: root)
        XCTAssertEqual(parameter.status, 0, parameter.output)
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
