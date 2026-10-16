import Darwin
import XCTest
@testable import Pensieve

extension CommandLinkInstallerTests {
    /// A fresh test process starts with the poisoned environment, then runs the unchanged
    /// production wrapper, so both Foundation and AppleScript see a real inherited-code attack.
    func assertPromptRejectsInheritedEnvironment() async throws {
        let fixture = try CommandLinkFixture()
        defer { fixture.clean() }
        let probe = try await BlockingWork.run { try Self.compilePromptProbe(in: fixture) }
        for poison in ["function", "trace"] {
            let marker = fixture.root + "/inherited-" + poison
            let quoted = "'" + marker.replacingOccurrences(of: "'", with: "'\\''") + "'"
            var environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "HOME": fixture.root]
            let variable: String
            if poison == "function" {
                variable = "BASH_FUNC_cd%%"
                environment[variable] = "() { /usr/bin/touch \(quoted); builtin cd \"$@\"; }"
            } else {
                variable = "SHELLOPTS"
                environment[variable] = "xtrace"
                environment["PS4"] = "$(/usr/bin/touch \(quoted))"
            }
            let result = try await BlockingWork.run {
                try CommandLinkFixture.run(probe, arguments: ["cd -P /; /bin/test -d .", variable], environment: environment)
            }
            XCTAssertEqual(result.0, 0, result.1)
            XCTAssertFalse(fixture.files.fileExists(at: marker),
                           "The production prompt must discard inherited \(poison) code before any shell starts")
        }
    }

    nonisolated private static func compilePromptProbe(in fixture: CommandLinkFixture) throws -> String {
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = fixture.root + "/AdministratorPrompt.swift"
        try fixture.files.copyFile(at: sourceRoot.appendingPathComponent("Pensieve/Services/AdministratorPrompt.swift").path,
                                   to: source)
        let main = fixture.root + "/main.swift"
        try fixture.files.writeFile(at: main, content: """
        import Foundation
        import Darwin
        guard getenv(CommandLine.arguments[2]) != nil else { exit(78) }
        do {
            try AppleScriptAdministratorPrompt(requiresAdministratorPrivileges: false).run(shellCommand: CommandLine.arguments[1])
        } catch {
            print(error.localizedDescription)
            exit(1)
        }
        """)
        let executable = fixture.root + "/prompt-probe"
        let compile = try CommandLinkFixture.run("/usr/bin/xcrun", arguments: ["swiftc", source, main, "-o", executable])
        XCTAssertEqual(compile.0, 0, compile.1)
        return executable
    }

    func assertUninstallDoesNotReadChangedPlist() async throws {
        let fixture = try CommandLinkFixture()
        defer { fixture.clean() }
        let app = fixture.root + "/PensieveFIFO.app"
        let plist = app + "/Contents/Info.plist"
        let info = try fixture.files.readData(at: Bundle.main.bundlePath + "/Contents/Info.plist")
        try fixture.files.createDirectory(at: app + "/Contents")
        try fixture.files.writeData(at: plist, data: info)
        try fixture.link(to: app + "/Contents/Helpers/pensieve")
        let expired = DispatchSemaphore(value: 0)
        // Self-releasing FIFO: a regressed reader is unblocked after the upper bound, without
        // ever leaving a hung privileged-step fixture or depending on the test host's main queue.
        let release = DispatchWorkItem {
            expired.signal()
            let descriptor = open(plist, O_WRONLY)
            if descriptor >= 0 {
                _ = info.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
                close(descriptor)
            }
        }
        defer {
            release.cancel()
            // Keep a reader until the release job finishes, including when the program never
            // reads the FIFO. A delayed osascript still meets the waiting writer after the deadline.
            let reader = open(plist, O_RDONLY | O_NONBLOCK)
            XCTAssertEqual(release.wait(timeout: .now() + TestWait.hostedActionTimeoutSeconds), .success)
            if reader >= 0 { close(reader) }
        }
        fixture.authorization.beforeRun = {
            try fixture.files.deleteFile(at: plist)
            XCTAssertEqual(mkfifo(plist, 0o600), 0)
            DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: release) // upper-bound: FIFO read deadline
        }
        let model = CommandLineSettingsModel(installer: fixture.installer())
        await model.perform(.uninstall)
        XCTAssertEqual(expired.wait(timeout: .now()), .timedOut, "The privileged step must not read the app's FIFO plist")
        XCTAssertNil(model.error)
        XCTAssertEqual(fixture.authorization.calls, 1)
        XCTAssertFalse(try fixture.files.entryExistsWithoutFollowingLinks(at: fixture.path))
    }
}

extension CommandLinkInstallerTests {
    func assertPromptPreservesOtherErrors() async throws {
        for message in ["User canceled. (128)", "Some other failure (-128)", "User canceled. (-128) (1)"] {
            let error = AppleScriptAdministratorPrompt.failure(status: 1, message: "0:1: execution error: " + message)
            XCTAssertEqual(error.code, 1, "Only osascript's cancellation diagnostic is cancellation")
            XCTAssertTrue(error.localizedDescription.contains(message))
        }
        let prompt = AppleScriptAdministratorPrompt(requiresAdministratorPrivileges: false)
        do {
            try await BlockingWork.run { try prompt.run(shellCommand: "printf '%s' 'fixture failure' >&2; exit 7") }
            XCTFail("A failed shell command must be reported")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("fixture failure"))
            XCTAssertNotEqual((error as NSError).code, -128)
        }
    }
}
