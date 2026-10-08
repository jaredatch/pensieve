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
        try assertRequiredArguments(requiredArguments)
    }

    func testRuntimeServicesRequireExplicitPaths() throws {
        try assertRequiredArguments([
            ("GitService", [("askpassHelperPath", "root")]),
            ("SkillStore", [("fileService", "files"), ("baseDir", "root")]),
            ("SyncEngine", [("gitService", "git"), ("lockPath", "root")]),
            ("SyncModel", [("git", "git"), ("root", "root")]),
            ("SyncAudit", [("appSupport", "root")]),
            ("MachineIdentity", [("appSupportDir", "root")]),
            ("DeployStateStore", [("fileService", "files"), ("appSupportDir", "root")]),
            ("FileWatchService", [("rootDir", "root")]),
            ("ImportScanner", [("fileService", "files"), ("claudeSkillsDir", "root"), ("grokSkillsDir", "root"),
                               ("cursorRulesDir", "root"), ("codexSkillsDir", "root"), ("storeRoot", "root")]),
            ("StoreMigrationService", [("skillStore", "store")]),
            ("CategoryStore", [("manifestRoot", "root")]),
            ("LaunchReconciler", [("migrationService", "StoreMigrationService(skillStore: store)"),
                                  ("root", "root"), ("lockPath", "root"), ("git", "git")]),
            ("SyncSetupModel", [("context", "context"), ("git", "git"), ("credentials", "credentials"),
                                ("root", "root"), ("lockPath", "root")]),
            ("ConflictResolutionModel", [("engine", "engine"), ("git", "git"), ("credentials", "credentials"),
                                         ("root", "root")]),
            ("GitHubCredentialSettingsModel", [("credentialStore", "credentials")]),
            ("MachineStateService", [("agentDetection", "detection"),
                                     ("deployState", "{ try state.read() }"), ("homeDirectory", "root")]),
            ("PlatformViewModel", [("linkService", "link"), ("cursorCompiler", "cursor"),
                                   ("agentDetection", "detection"), ("deployStateStore", "state"), ("skillsDirectory", "root")]),
            ("SkillLibraryViewModel", [("skillStore", "store"), ("fileWatchService", "watcher"), ("manifestRoot", "root")]),
            ("ImportViewModel", [("scanner", "scanner"), ("skillStore", "store"), ("manifestRoot", "root")]),
            ("DeployReconciler", [("fileService", "files"), ("deployState", "state"), ("pensieveSkillsDir", "root"),
                                   ("agentSkillDirs", "[]"), ("cursorRulesDir", "root")]),
            ("DeployStateBackfill", [("store", "state"),
                                     ("paths",
                                         "DeployStateBackfillPaths(pensieveSkillsDir: root, cursorUserRulesDir: root, " +
                                         "userSkillsRoot: { _ in nil })")]),
            ("await coordinator.configure", [("engine", "engine"), ("git", "git"), ("credentials", "credentials"),
                                              ("root", "root"), ("audit", "SyncAudit(appSupport: root)"),
                                              ("machine",
                                                  "(identity: MachineIdentity(appSupportDir: root), " +
                                                  "stateService: paths.makeMachineStateService(defaults: .standard))")]),
            ("SyncLock.tryAcquire", [("at", "root")])
        ])
    }

    private let prelude = """
            import Foundation
            import SwiftData
            @testable import Pensieve
            @MainActor func constructionClients() async {
            let root = "/unused-typecheck-only"
            let git = GitService(askpassHelperPath: root)
            let credentials = InMemoryCredentialStore()
            let files = FileService()
            let store = SkillStore(fileService: files, baseDir: root)
            let paths = AppRuntimePaths(storeRoot: root, appSupportDir: root)
            let engine = paths.makeSyncEngine()
            let detection = AgentDetectionService(homeDirectory: root)
            let link = LinkService(fileService: files, paths: paths.deployPaths)
            let cursor = CursorCompiler(fileService: files, skillStore: store, userRulesDirectory: root)
            let state = DeployStateStore(fileService: files, appSupportDir: root)
            let watcher = FileWatchService(rootDir: root)
            let scanner = paths.makeImportScanner()
            let container = try! AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
            let context = ModelContext(container)
            let coordinator = SyncCoordinator(modelContainer: context.container)
            let hasher = SkillInstallService(gitService: git, credentialStore: credentials,
                                            scratchRoot: root, storeRoot: root, lockPath: root)
            """ + "\n"

    private func assertRequiredArguments(
        _ requiredArguments: [(type: String, arguments: [(label: String, value: String)])]
    ) throws {
        let directory = TestTemporaryDirectory.url.appendingPathComponent("GitHubConstruction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let valid = requiredArguments.map { client(type: $0.type, arguments: $0.arguments) }.joined(separator: "\n")
        let control = try typecheck(prelude + valid + "\n}", fileName: "control.swift", directory: directory)
        XCTAssertEqual(control.exit, 0, control.diagnostics)
        guard control.exit == 0 else { return }
        var clients: [String] = []
        var expected: [Omission] = []
        let firstLine = prelude.components(separatedBy: "\n").count
        for requirement in requiredArguments {
            for omitted in requirement.arguments {
                let source = client(type: requirement.type, arguments: requirement.arguments.filter { $0.label != omitted.label })
                expected.append(Omission(line: firstLine + clients.count, type: requirement.type, label: omitted.label))
                clients.append("@MainActor func omitted_\(clients.count)() async { \(source) }")
            }
        }
        let result = try typecheck(prelude + clients.joined(separator: "\n") + "\n}", fileName: "omitted.swift",
            directory: directory)
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
