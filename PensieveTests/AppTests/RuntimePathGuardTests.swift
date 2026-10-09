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
        let inventory = try fixtureInventory(in: directory)
        let cases = rejectedSources(members: try XCTUnwrap(inventory["location"]))
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
        try assertUnclassifiedDefinitions(in: directory)
        try assertHarmlessSources(in: directory)
    }

    private func rejectedSources(members: [String]) -> [String] {
        members.flatMap { member in
            ["init(root: String = Constants.\(member)) {}", "let root = PathConstants.\(member)"]
        } + ["init(credentials: CredentialStoreProtocol = KeychainCredentialStore()) {}",
             "let credentials = KeychainCredentialStore()", "let credentials = KeychainCredentialStore.init()",
             "let credentials = KeychainCredentialStore.self.init()",
             "init(credentials: CredentialStoreProtocol = KeychainCredentialStore.self.init()) {}",
             "init(lock: String = PathConstants /* nested /* text */ comment */ .\n" +
                 "pensieveAppSupportDir + \"/sync.lock\") {}",
             "let root = \"\\(Constants.pensieveBaseDir)\"", "let paths: RuntimePaths = .production",
             "init(p: RuntimePaths! = .production) {}", "init(p: RuntimePaths? = .production) {}",
             "init(p: Box<RuntimePaths> = .production) {}", "init(p: (RuntimePaths) = .production) {}",
             "var paths: RuntimePaths; init() { self.paths = .production }",
             "let p: RuntimePaths = (.production)", "let environment: Env = .production",
             "let p = RuntimePaths.production", "let p = AppRuntimePaths.production",
             "let x = a+/* \" */ Constants.homeDirectory // \"",
             "init(root: String = Constants.geminiUserSkillsDir) {}",
             "let c = Constants.self; let root = c.pensieveBaseDir",
             "let c = PathConstants.self; let root = c.pensieveBaseDir",
             "func make() -> RuntimePaths { .production }",
             "let p: RuntimePaths = .`production`",
             "let x = root == RuntimePaths.production.storeRoot",
             "let x = root == .production.storeRoot",
             "let x = wrap(.production) == e",
             "static func live() -> AppRuntimePaths { Self.production }",
             "extension AppRuntimePaths { static func live() -> AppRuntimePaths { self.production } }",
             "let p = RuntimePaths.self.production",
             "let p = AppRuntimePaths.self.production",
             "let p = (RuntimePaths.self).production",
             "let live = type(of: p).production",
             "let live = (type(of: p)).production",
             "let live = Wrapper<RuntimePaths>(.production) == expected",
             "let live = Wrapper<Box<RuntimePaths>>((.production)) != expected",
             "let regex = #/{/#; enum Constants { static let homeDirectory = \"root\" }; let root = Constants.homeDirectory",
             "func visit() { for case let p in [RuntimePaths.production] {} }",
             "func visit() { for case let p in [AppRuntimePaths.production] {} }",
             "func visit() { for case let p in [.production] {} }"]
    }

    private func fixtureInventory(in directory: URL) throws -> [String: [String]] {
        let source = repository.appendingPathComponent("script/runtime-path-members.json")
        var inventory = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: source))
        inventory["nonLocation", default: []].append("maxBodyBytes")
        let destination = directory.appendingPathComponent("script/runtime-path-members.json")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(inventory).write(to: destination)
        return inventory
    }

    private func assertUnclassifiedDefinitions(in directory: URL) throws {
        for type in ["PathConstants", "Constants"] {
            let relative = "Pensieve/Utilities/" + type + ".swift"
            let path = directory.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let declarations = [("static let geminiUserSkillsDir = 8", "geminiUserSkillsDir"),
                                ("static let newSafeLimit = 8", "newSafeLimit"),
                                ("static private(set) var foo = 1", "foo"),
                                ("static subscript(i: Int) -> Int { i }", "subscript")]
            for (declaration, member) in declarations {
                for prefix in ["", "let regex = #/{/#\n", "}\n"] {
                    try (prefix + "enum " + type + " {\n" + declaration + "\n}\n").write(
                        to: path, atomically: true, encoding: .utf8)
                    let result = try runGuard(root: directory)
                    XCTAssertEqual(result.status, 1, result.output)
                    let line = prefix.isEmpty ? 2 : 3
                    XCTAssertTrue(result.output.contains(relative + ":\(line):"), result.output)
                    XCTAssertTrue(result.output.contains(type + "." + member + ";"), result.output)
                }
            }
            try FileManager.default.removeItem(at: path)
        }
    }

    private func assertHarmlessSources(in directory: URL) throws {
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
            "func isLive(_ e: Env) -> Bool { .production == e }",
            "func isLive(_ e: Env) -> Bool { (.production) != e }",
            "func isLive(_ e: Env) -> Bool { e == (.production) }",
            "func check(_ e: Env) { guard e == .production else { return } }",
            "func check(_ e: Env) { guard e != (.production) else { return } }",
            "func isLive(_ e: Env) -> Bool { switch e { case .production: return true; default: return false } }",
            "func isLive(_ e: Env) -> Bool { if case .production = e { return true }; return false }",
            "let z = a+// Constants.homeDirectory\n",
            "let z = a+/* \" Constants.homeDirectory */b",
            "let n = Constants.maxBodyBytes",
            "let n = PathConstants.maxBodyBytes",
            "let value = settings.production",
            "let value = config?.production",
            "let value = settings!.production",
            "let value = self.production",
            "let value = settings().production",
            "func isLive(_ e: Env) -> Bool { e == (Pensieve.RuntimePaths.production) }",
            "func loop(_ e: Env) { while (.production) != e {} }",
            "let compare = { e in (.production) == e }",
            "struct V { private enum Constants { static let fade = 0.2 }; let d = Constants.fade }",
            "struct V { private enum PathConstants { static let fade = 0.2 }; let d = PathConstants.fade }"
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
