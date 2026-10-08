import XCTest
@testable import Pensieve

/// Owns the architectural guard through its executable boundary. Fixtures prove that defaults in
/// newly named app/daemon files fail with a source location; inert text and runtime resolution pass.
final class RuntimePathGuardTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testAppAndDaemonSourcesDoNotResolveLiveDefaults() throws {
        let result = try runGuard(root: repository)
        XCTAssertEqual(result.status, 0, result.output)
    }

    func testGuardRejectsInitializerAndPropertyDefaultsAndNamesTheirLocations() throws {
        let directory = TestTemporaryDirectory.url.appendingPathComponent("RuntimePathGuard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Pensieve"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("PensieveDaemon"),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let members = ["pensieveBaseDir", "pensieveSkillsDir", "pensieveAppSupportDir", "gitAskpassHelperPath",
                       "claudeCodeUserSkillsDir", "grokUserSkillsDir", "codexUserSkillsDir", "openClawUserSkillsDir",
                       "hermesUserSkillsDir", "cursorUserRulesDir", "homeDirectory"]
        var cases = members.flatMap { member in
            ["init(root: String = Constants.\(member)) {}", "let root = PathConstants.\(member)"]
        }
        cases += ["init(credentials: CredentialStoreProtocol = KeychainCredentialStore()) {}",
                  "let credentials = KeychainCredentialStore()",
                  "let credentials = KeychainCredentialStore.init()",
                  "init(lock: String = PathConstants /* nested /* text */ comment */ .\n" +
                      "pensieveAppSupportDir + \"/sync.lock\") {}",
                  "let root = \"\\(Constants.pensieveBaseDir)\"",
                  "let paths: RuntimePaths = .production"]
        for folder in ["Pensieve", "PensieveDaemon"] {
            let path = directory.appendingPathComponent(folder + "/NewCollaborator.swift")
            for source in cases {
                try ("struct NewCollaborator {\n" + source + "\n}\n").write(to: path, atomically: true, encoding: .utf8)
                let result = try runGuard(root: directory)
                XCTAssertEqual(result.status, 1, source)
                XCTAssertTrue(result.output.contains(folder + "/NewCollaborator.swift:2:"), result.output)
            }
            try assertPermittedSources(in: directory, at: path)
            try FileManager.default.removeItem(at: path)
        }
        let harmless = """
            struct Neutral {
                // let root = Constants.pensieveBaseDir
                /* let credential = KeychainCredentialStore() */
                let documentation = "PathConstants.pensieveAppSupportDir"
                let category = PathConstants.hermesDefaultCategory
                init(root: String, credential: CredentialStoreProtocol, limit: Int = 4) {}
            }
            """
        try harmless.write(to: directory.appendingPathComponent("Pensieve/Neutral.swift"), atomically: true, encoding: .utf8)
        let resolution = directory.appendingPathComponent("Pensieve/Utilities/RuntimePaths.swift")
        try FileManager.default.createDirectory(at: resolution.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "let paths = Constants.pensieveBaseDir\nlet credentials = KeychainCredentialStore()".write(
            to: resolution, atomically: true, encoding: .utf8)
        let accepted = try runGuard(root: directory)
        XCTAssertEqual(accepted.status, 0, accepted.output)
    }

    private func assertPermittedSources(in directory: URL, at path: URL) throws {
        let permitted = [
            "func isLive(_ e: Env) -> Bool { e == .production }",
            "func isLive(_ e: Env) -> Bool { e != .production }",
            "let environment: Env = .production",
            "let n = Constants.maxBodyBytes",
            "let n = PathConstants.maxBodyBytes"
        ]
        for source in permitted {
            try ("struct NewCollaborator {\n" + source + "\n}\n").write(to: path, atomically: true, encoding: .utf8)
            let result = try runGuard(root: directory)
            XCTAssertEqual(result.status, 0, source + "\n" + result.output)
        }
    }

    private func runGuard(root: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", repository.appendingPathComponent("script/check-live-defaults.py").path,
                             "--root", root.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(bytes: data, encoding: .utf8) ?? "invalid UTF-8")
    }
}
