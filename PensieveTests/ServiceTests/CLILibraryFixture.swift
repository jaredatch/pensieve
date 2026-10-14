import Darwin
import Foundation
import SwiftData
import XCTest
@testable import Pensieve

/// The real runtime and services over owned folders. Only remote resolution substitutes a local
/// repository for GitHub; git, discovery, pin verification, filesystem and persistence stay real.
@MainActor
final class CLILibraryFixture {
    let endpoint: SocketTestDirectory
    let files = FileService()
    let root: String
    let repository: String
    let paths: AppRuntimePaths
    let runtime: AppRuntime
    let git: GitService
    let sourceURL = "https://github.com/fixture/skills"
    var context: ModelContext { runtime.container.mainContext }

    init(readOnly: Bool = false, remoteGate: CLILibraryRemoteGate? = nil) throws {
        endpoint = try SocketTestDirectory()
        root = TestTemporaryDirectory.path + "CLILibrary-" + UUID().uuidString
        repository = root + "/upstream"
        paths = AppRuntimePaths(storeRoot: root + "/home/.pensieve", appSupportDir: endpoint.path)
        try files.createDirectory(at: repository)
        try files.createDirectory(at: root + "/home/.claude")
        try files.createDirectory(at: paths.skillsDir)
        git = GitService(fileService: files, askpassHelperPath: root + "/askpass")
        let remote = "file://" + repository
        let validator: InstallRemotePolicy.Validator = { value in
            guard let valid = InstallRemotePolicy.validateGitHubRepository(value) else { return nil }
            remoteGate?.waitIfArmed()
            return ValidatedInstallRemote(repo: valid.repo, cloneRemote: remote)
        }
        let installer = SkillInstallService(gitService: git, credentialStore: InMemoryCredentialStore(),
            scratchRoot: root + "/install-scratch", storeRoot: paths.storeRoot, lockPath: paths.syncLockPath,
            remoteValidator: validator)
        let checker = UpdateCheckService(gitService: git, credentialStore: InMemoryCredentialStore(), contentHasher: installer,
            scratchRoot: root + "/update-scratch", storeRoot: paths.storeRoot, remoteValidator: validator)
        let deployPaths = DeployPaths(skillsDirectory: paths.skillsDir,
            userSkillsDirectories: [.claudeCode: root + "/home/.claude/skills"],
            cursorUserRulesDirectory: root + "/home/.cursor/rules")
        let platform = PlatformViewModel(fileService: files, linkService: LinkService(fileService: files, paths: deployPaths),
            cursorCompiler: CursorCompiler(fileService: files,
                skillStore: SkillStore(fileService: files, baseDir: paths.skillsDir, storeRoot: paths.storeRoot),
                userRulesDirectory: deployPaths.cursorUserRulesDirectory),
            agentDetection: AgentDetectionService(probe: SystemEnvironmentProbe(fileService: files, pathEntries: []),
                homeDirectory: root + "/home"),
            deployStateStore: DeployStateStore(fileService: files, appSupportDir: endpoint.path),
            skillsDirectory: paths.skillsDir)
        let defaults = try paths.makeDefaults()
        defaults.set(false, forKey: AppRuntime.backgroundSyncEnabledKey)
        defaults.set("off", forKey: UpdateCheckSchedule.frequencyKey)
        let container: ModelContainer?
        if readOnly {
            let url = URL(fileURLWithPath: root + "/readonly.sqlite")
            do {
                let seed = try AppRuntime.makeContainer(configuration: ModelConfiguration(url: url))
                try seed.mainContext.save()
            }
            container = try AppRuntime.makeContainer(configuration: ModelConfiguration(url: url, allowsSave: false))
        } else { container = nil }
        runtime = try AppRuntime(container: container, platformVM: platform, defaults: defaults, paths: paths,
            updateCheckOperation: paths.makeUpdateCheckOperation(service: checker),
            updatesViewModelOperations: .init(updateCheckService: checker, skillInstallService: installer))
    }

    func start() async throws {
        try await rawGit(["init", "--initial-branch=main", repository])
        try files.createDirectory(at: repository + "/skills/foo")
        try files.writeFile(at: repository + "/skills/foo/SKILL.md", content: Self.document("original"))
        try files.writeFile(at: repository + "/skills/foo/asset.txt", content: "original asset")
        try await commit()
        runtime.start()
        await TestWait.until(failureMessage: "Real runtime readiness") { self.runtime.commandsReady }
        XCTAssertNil(runtime.commandServerError)
    }

    func stop() {
        runtime.commandServer?.stop()
        runtime.library.stopWatching()
        try? files.deleteDirectory(at: root)
    }

    static func document(_ body: String) -> String { "---\nname: Foo\ndescription: Fixture skill\n---\n" + body + "\n" }

    func commit() async throws {
        try await rawGit(["-C", repository, "add", "-A"])
        try await rawGit(["-C", repository, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com",
            "commit", "-m", "fixture"])
    }

    func rawGit(_ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let result = try await BlockingWork.run { try CLIProcessProbe.run(process, timeout: 30) }
        XCTAssertEqual(result.status, 0)
    }

    func run(_ arguments: [String], exit: Int32 = 0, terminal: Bool = false,
             environment extra: [String: String] = [:],
             beforeConfirmation: (() async throws -> Void)? = nil) async throws -> CLIEnvelope {
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/pensieve")
        process.arguments = arguments + ["--json", "--app-support", paths.appSupportDir]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = root + "/home"
        environment["CFFIXED_USER_HOME"] = root + "/home"
        environment.merge(extra) { _, new in new }
        process.environment = environment
        let output = Pipe(), errors = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardError = errors
        var controllerFD: Int32 = -1, terminalFD: Int32 = -1
        if terminal {
            guard openpty(&controllerFD, &terminalFD, nil, nil, nil) == 0 else { throw POSIXError(.EIO) }
            process.standardInput = FileHandle(fileDescriptor: terminalFD, closeOnDealloc: false)
            if beforeConfirmation == nil { _ = "yes\n".withCString { Darwin.write(controllerFD, $0, 4) } }
        } else {
            process.standardInput = input
            input.fileHandleForWriting.write(Data("yes\n".utf8))
            try input.fileHandleForWriting.close()
        }
        defer { if controllerFD >= 0 { Darwin.close(controllerFD); Darwin.close(terminalFD) } }
        async let running = BlockingWork.run { try CLIProcessProbe.run(process, timeout: 40) }
        var prefix = Data()
        if let beforeConfirmation {
            prefix = try await BlockingWork.run { try Self.readPrompt(from: errors.fileHandleForReading) }
            try await beforeConfirmation()
            _ = "yes\n".withCString { Darwin.write(controllerFD, $0, 4) }
        }
        let result = try await running
        let bytes = try output.fileHandleForReading.readToEnd() ?? Data()
        let diagnostics = prefix + (try errors.fileHandleForReading.readToEnd() ?? Data())
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.status, exit, String(data: bytes + diagnostics, encoding: .utf8) ?? "Invalid UTF-8")
        if terminal, extra["PENSIEVE_NO_INPUT"] != "1", !arguments.contains("--no-input") {
            XCTAssertTrue((String(data: diagnostics, encoding: .utf8) ?? "").contains("Apply this plan?"))
        } else { XCTAssertFalse((String(data: diagnostics, encoding: .utf8) ?? "").contains("Apply this plan?")) }
        return try JSONDecoder().decode(CLIEnvelope.self, from: bytes)
    }

    func skill(_ slug: String = "foo") throws -> Skill {
        try XCTUnwrap(context.fetch(FetchDescriptor<Skill>()).first { $0.directoryName == slug })
    }

    func tree(_ path: String) throws -> [String: Data] {
        guard files.fileExists(at: path) || files.directoryExists(at: path) || files.isSymlink(at: path) else { return [:] }
        if files.isSymlink(at: path) { return [path: Data(try files.symlinkTarget(at: path).utf8)] }
        if !files.directoryExists(at: path) { return [path: try files.readData(at: path)] }
        var result: [String: Data] = [path: Data()]
        for name in try files.listDirectory(at: path) { result.merge(try tree(path + "/" + name)) { first, _ in first } }
        return result
    }
}

/// Delays only the fixture network boundary; the window still executes its real update operation.
final class CLILibraryRemoteGate {
    private let lock = NSLock()
    private var armed = false
    let gate: TestWait.Gate
    init(owner: XCTestCase) { gate = TestWait.Gate(owner: owner) }
    func arm() { lock.lock(); armed = true; lock.unlock() }
    func waitIfArmed() {
        lock.lock()
        let shouldWait = armed
        armed = false
        lock.unlock()
        if shouldWait { try? gate.wait(timeout: .seconds(45)) }
    }
}
