import Darwin
import Foundation
import XCTest
@testable import Pensieve

/// Replaces only authorization: invokes the shipped helper without elevation against owned folders.
/// Its pre-run callback models changes while the real admin dialog would be open. No host paths change.
final class CommandLinkFixture {
    let files = FileService()
    let root = TestTemporaryDirectory.path + "CommandLink-" + UUID().uuidString
    let authorization = FixtureCommandAuthorization()
    var directory: String { root + "/local/bin" }
    var path: String { directory + "/pensieve" }
    var removedExecutable: String { root + "/PensieveRemoved.app/Contents/Helpers/pensieve" }
    var executable: String { Bundle.main.bundlePath + "/Contents/Helpers/pensieve" }

    init() throws { try files.createDirectory(at: root + "/local") }
    func clean() { try? files.deleteDirectory(at: root) }

    func installer(user: UInt32 = getuid(), homebrew: [String] = [], executable: String? = nil) -> CommandLinkInstaller {
        CommandLinkInstaller(files: files, directory: directory, executable: executable ?? self.executable,
                             user: user, homebrewDirectories: homebrew, authorization: authorization)
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

final class FixtureCommandAuthorization: CommandLinkAuthorizing {
    var beforeRun: (() throws -> Void)?
    var cancelled = false
    private(set) var calls = 0

    func run(_ request: CommandLinkRequest) throws {
        calls += 1
        if cancelled { throw AdminCommandLinkAuthorization.Cancelled() }
        try beforeRun?()
        let encoded = try JSONEncoder().encode(request).base64EncodedString()
        let result = try CommandLinkFixture.run(Bundle.main.bundlePath + "/Contents/Helpers/pensieve",
                                                arguments: ["--manage-command-link", encoded])
        guard result.0 == 0 else { throw CommandLinkError(message: result.1) }
    }
}
