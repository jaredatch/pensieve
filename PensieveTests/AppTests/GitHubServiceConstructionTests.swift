import XCTest
@testable import Pensieve

/// Typechecks clients of the built module, so a reintroduced default makes the omitted-argument
/// client compile. The fully named client must compile first; unrelated compiler errors cannot pass.
final class GitHubServiceConstructionTests: XCTestCase {
    private struct Omission {
        let line: Int
        let type: String
        let label: String
    }

    private let requiredArguments: [(type: String, arguments: [(label: String, value: String)])] = [
        ("SkillInstallService", [("gitService", "git"), ("credentialStore", "credentials"),
                                 ("scratchRoot", "root"), ("storeRoot", "root"), ("lockPath", "root")]),
        ("UpdateCheckService", [("gitService", "git"), ("credentialStore", "credentials"),
                                ("contentHasher", "hasher"), ("scratchRoot", "root"), ("storeRoot", "root")]),
        ("UpstreamHistoryService", [("gitService", "git"), ("credentialStore", "credentials"),
                                    ("contentHasher", "hasher"), ("scratchRoot", "root")]),
        ("SkillInstallService.cleanupScratchRoot", [("scratchRoot", "root")]),
        ("UpdateCheckService.cleanupScratchRoot", [("scratchRoot", "root")]),
        ("UpstreamHistoryService.cleanupScratchRoot", [("scratchRoot", "root")]),
        ("SkillInstallService.cleanupVendorTemps", [("storeRoot", "root"), ("lockPath", "root")])
    ]

    func testGitHubServicesRequireTheirCallersDependencies() throws {
        let directory = TestTemporaryDirectory.url.appendingPathComponent("GitHubConstruction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let prelude = """
            import Foundation
            @testable import Pensieve
            let root = "/unused-typecheck-only"
            let git = GitService(askpassHelperPath: root)
            let credentials = InMemoryCredentialStore()
            let hasher = SkillInstallService(gitService: git, credentialStore: credentials,
                                            scratchRoot: root, storeRoot: root, lockPath: root)
            """ + "\n"
        let valid = requiredArguments.map { client(type: $0.type, arguments: $0.arguments) }.joined(separator: "\n")
        let control = try typecheck(prelude + valid, fileName: "control.swift", directory: directory)
        XCTAssertEqual(control.exit, 0, control.diagnostics)
        guard control.exit == 0 else { return }
        var clients: [String] = []
        var expected: [Omission] = []
        let firstLine = prelude.components(separatedBy: "\n").count
        for requirement in requiredArguments {
            for omitted in requirement.arguments {
                let source = client(type: requirement.type, arguments: requirement.arguments.filter { $0.label != omitted.label })
                expected.append(Omission(line: firstLine + clients.count, type: requirement.type, label: omitted.label))
                clients.append("func omitted_\(clients.count)() { \(source) }")
            }
        }
        let result = try typecheck(prelude + clients.joined(separator: "\n"), fileName: "omitted.swift", directory: directory)
        XCTAssertNotEqual(result.exit, 0)
        let errors = result.diagnostics.components(separatedBy: "\n").filter { $0.contains(": error:") }
        XCTAssertEqual(errors.count, expected.count, result.diagnostics)
        for omission in expected {
            let location = directory.appendingPathComponent("omitted.swift").path + ":\(omission.line):"
            let message = "missing argument for parameter '\(omission.label)'"
            let description = "\(omission.type) accepted an omitted \(omission.label) at line \(omission.line)"
            XCTAssertTrue(errors.contains { $0.hasPrefix(location) && $0.contains(message) },
                          "\(description):\n\(result.diagnostics)")
        }
    }

    private func client(type: String, arguments: [(label: String, value: String)]) -> String {
        "_ = \(type)(" + arguments.map { "\($0.label): \($0.value)" }.joined(separator: ", ") + ")"
    }

    private func typecheck(_ source: String, fileName: String, directory: URL) throws -> (exit: Int32, diagnostics: String) {
        let sourceURL = directory.appendingPathComponent(fileName)
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        let products = try productDirectory()
        let derived = products.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sparkle = "SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "swiftc", "-typecheck", "-diagnostic-style", "llvm", "-target", try targetTriple(),
            "-I", products.path, "-F", products.path,
            "-F", derived.appendingPathComponent(sparkle).path,
            "-I", derived.appendingPathComponent("SourcePackages/checkouts/Yams/Sources/CYaml/include").path,
            sourceURL.path
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(bytes: data, encoding: .utf8) ?? "invalid compiler output")
    }

    private func targetTriple() throws -> String {
        let deployment = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String)
        #if arch(arm64)
        return "arm64-apple-macos\(deployment)"
        #elseif arch(x86_64)
        return "x86_64-apple-macos\(deployment)"
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    private func productDirectory() throws -> URL {
        // The host embeds the test bundle inside its app. Find the enclosing build products rather
        // than assuming the bundle's immediate parent holds the importable module.
        var directory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("Pensieve.swiftmodule").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent != directory else { throw CocoaError(.fileNoSuchFile) }
            directory = parent
        }
        return directory
    }
}
