import Darwin
import Foundation
import XCTest
@testable import Pensieve

/// Replaces only the elevation wrapper: executes the production command unelevated in owned folders.
/// Its pre-run callback models changes while the real admin dialog would be open. No host paths change.
final class CommandLinkFixture {
    let files = FileService()
    let root = TestTemporaryDirectory.path + "CommandLink space ' \" $(false)-" + UUID().uuidString
    let authorization = FixtureCommandAuthorization()
    var directory: String { root + "/local/bin" }
    var path: String { directory + "/pensieve" }
    var removedExecutable: String { root + "/PensieveRemoved.app/Contents/Helpers/pensieve" }
    var executable: String { Bundle.main.bundlePath + "/Contents/Helpers/pensieve" }

    init() throws { try files.createDirectory(at: root + "/local") }
    func clean() { try? files.deleteDirectory(at: root) }

    func installer(user: UInt32 = getuid(), homebrew: [String] = [], executable: String? = nil) -> CommandLinkInstaller {
        CommandLinkInstaller(files: files, directory: directory, executable: executable ?? self.executable,
                             user: user, homebrewDirectories: homebrew,
                             authorization: AdminCommandLinkAuthorization(prompt: authorization))
    }

    func link(to target: String) throws { try files.createSymlink(at: path, pointingTo: target) }

    static func run(_ executable: String, arguments: [String], environment: [String: String]? = nil) throws -> (Int32?, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let result = try CLIProcessProbe.run(process, timeout: 15)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (result.status, String(data: data, encoding: .utf8) ?? "invalid UTF-8")
    }
}

final class FixtureCommandAuthorization: AdministratorPromptRunning {
    var beforeRun: (() throws -> Void)?
    var cancelled = false
    private(set) var calls = 0

    private(set) var commands: [String] = []
    private(set) var promptThreads: [Bool] = []

    func run(_ request: CommandLinkRequest) throws {
        try AdminCommandLinkAuthorization(prompt: self).run(request)
    }

    func run(shellCommand: String) throws {
        calls += 1
        commands.append(shellCommand)
        promptThreads.append(Thread.isMainThread)
        if cancelled { throw NSError(domain: "Fixture.AdministratorPrompt", code: -128) }
        try beforeRun?()
        let result = try CommandLinkFixture.run("/bin/sh", arguments: ["-c", "umask 077\n" + shellCommand])
        guard result.0 == 0 else { throw CommandLinkError(message: result.1) }
    }
}
