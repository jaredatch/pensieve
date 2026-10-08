import XCTest
@testable import Pensieve

/// Typechecks clients of the built module, so a reintroduced default makes the omitted-argument
/// client compile. The fully named client must compile first; unrelated compiler errors cannot pass.
final class GitHubServiceConstructionTests: XCTestCase {
    private let requiredArguments: [(type: String, arguments: [(label: String, value: String)])] = [
        ("SkillInstallService", [("gitService", "git"), ("credentialStore", "credentials"),
                                 ("scratchRoot", "root"), ("storeRoot", "root"), ("lockPath", "root")]),
        ("UpdateCheckService", [("gitService", "git"), ("credentialStore", "credentials"),
                                ("contentHasher", "hasher"), ("scratchRoot", "root"), ("storeRoot", "root")]),
        ("UpstreamHistoryService", [("gitService", "git"), ("credentialStore", "credentials"),
                                    ("contentHasher", "hasher"), ("scratchRoot", "root")])
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
        let control = try typecheck(prelude + valid, directory: directory)
        XCTAssertEqual(control.exit, 0, control.diagnostics)
        guard control.exit == 0 else { return }
        for requirement in requiredArguments {
            for omitted in requirement.arguments {
                let source = client(type: requirement.type, arguments: requirement.arguments.filter { $0.label != omitted.label })
                let result = try typecheck(prelude + source, directory: directory)
                XCTAssertNotEqual(result.exit, 0, "\(requirement.type) accepted an omitted \(omitted.label)")
                let expected = "missing argument for parameter '\(omitted.label)'"
                XCTAssertTrue(result.diagnostics.contains(expected), result.diagnostics)
            }
        }
    }

    private func client(type: String, arguments: [(label: String, value: String)]) -> String {
        "_ = \(type)(" + arguments.map { "\($0.label): \($0.value)" }.joined(separator: ", ") + ")"
    }

    private func typecheck(_ source: String, directory: URL) throws -> (exit: Int32, diagnostics: String) {
        let sourceURL = directory.appendingPathComponent("client.swift")
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        let products = try productDirectory()
        let derived = products.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sparkle = "SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "swiftc", "-typecheck", "-target", "arm64-apple-macos26.0", "-I", products.path, "-F", products.path,
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
