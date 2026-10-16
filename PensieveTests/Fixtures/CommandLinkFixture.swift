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
    var removedExecutable: String { root + "/Work.app/Contents/Helpers/pensieve" }
    var executable: String { Bundle.main.bundlePath + "/Contents/Helpers/pensieve" }

    init() throws { try files.createDirectory(at: root + "/local") }
    func clean() { try? files.deleteDirectory(at: root) }

    func installer(user: UInt32 = getuid(), homebrew: [String] = [], executable: String? = nil,
                   files: FileServiceProtocol? = nil) -> CommandLinkInstaller {
        CommandLinkInstaller(files: files ?? self.files, directory: directory, executable: executable ?? self.executable,
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
    var failureMessage: String?
    var cancelled = false
    var cancellationMessage = "User canceled. (-128)"
    private(set) var calls = 0

    private(set) var commands: [String] = []
    private(set) var promptThreads: [Bool] = []

    func run(_ request: CommandLinkRequest) throws {
        try AdminCommandLinkAuthorization(prompt: self).run(request)
    }

    func run(shellCommand: String, action: CommandLinkAction) throws {
        calls += 1
        commands.append(shellCommand)
        promptThreads.append(Thread.isMainThread)
        if cancelled {
            throw AppleScriptAdministratorPrompt.failure(status: 1, message: "0:1: execution error: " + cancellationMessage)
        }
        if let failureMessage { throw AppleScriptAdministratorPrompt.failure(status: 1, message: failureMessage) }
        try beforeRun?()
        try AppleScriptAdministratorPrompt(requiresAdministratorPrivileges: false)
            .run(shellCommand: "umask 077\n" + shellCommand, action: action)
    }
}

/// Forwards filesystem behavior, swapping the fixture leaf once after capturing its inspected entry.
final class LeafReadSwappingFileService: FileServiceProtocol {
    private let base = FileService()
    let path: String
    var afterRead: (() throws -> Void)?

    init(path: String, afterRead: @escaping () throws -> Void) {
        self.path = path
        self.afterRead = afterRead
    }

    func commandLinkEntry(at path: String) throws -> CommandLinkEntry? {
        let entry = try base.commandLinkEntry(at: path)
        if path == self.path, let callback = afterRead {
            afterRead = nil
            try callback()
        }
        return entry
    }
    func changeCommandLink(_ request: CommandLinkRequest) throws { try base.changeCommandLink(request) }
    func realPath(at path: String) -> String { base.realPath(at: path) }
    func entryExistsWithoutFollowingLinks(at path: String) throws -> Bool {
        try base.entryExistsWithoutFollowingLinks(at: path)
    }
    func readRegularFileData(at path: String, maximumBytes: Int) throws -> Data {
        try base.readRegularFileData(at: path, maximumBytes: maximumBytes)
    }

    func listDirectory(at path: String) throws -> [String] { try base.listDirectory(at: path) }
    func readFile(at path: String) throws -> String { try base.readFile(at: path) }
    func readData(at path: String) throws -> Data { try base.readData(at: path) }
    func writeFile(at path: String, content: String) throws { try base.writeFile(at: path, content: content) }
    func deleteFile(at path: String) throws { try base.deleteFile(at: path) }
    func fileExists(at path: String) -> Bool { base.fileExists(at: path) }
    func isExecutableFile(at path: String) -> Bool { base.isExecutableFile(at: path) }
    func directoryExists(at path: String) -> Bool { base.directoryExists(at: path) }
    func createDirectory(at path: String) throws { try base.createDirectory(at: path) }
    func deleteDirectory(at path: String) throws { try base.deleteDirectory(at: path) }
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {
        try base.createSymlink(at: linkPath, pointingTo: targetPath)
    }
    func symlinkTarget(at path: String) throws -> String { try base.symlinkTarget(at: path) }
    func isSymlink(at path: String) -> Bool { base.isSymlink(at: path) }
    func isRegularFile(at path: String) -> Bool { base.isRegularFile(at: path) }
    func contentsHash(at path: String) throws -> String { try base.contentsHash(at: path) }
}
