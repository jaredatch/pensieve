import Darwin
import XCTest
@testable import Pensieve

extension CommandLinkInstallerTests {
    func assertPromptRejectsInheritedEnvironment() async throws {
        let fixture = try CommandLinkFixture()
        defer { fixture.clean() }
        let names = ["BASH_FUNC_cd%%", "SHELLOPTS", "PS4"]
        let saved = names.map { name in getenv(name).map { String(cString: $0) } }
        addTeardownBlock {
            for (name, value) in zip(names, saved) {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
        }
        for poison in ["function", "trace"] {
            for name in names { unsetenv(name) }
            let marker = fixture.root + "/inherited-" + poison
            let quoted = "'" + marker.replacingOccurrences(of: "'", with: "'\\''") + "'"
            if poison == "function" {
                setenv("BASH_FUNC_cd%%", "() { /usr/bin/touch \(quoted); builtin cd \"$@\"; }", 1)
            } else {
                setenv("SHELLOPTS", "xtrace", 1)
                setenv("PS4", "$(/usr/bin/touch \(quoted))", 1)
            }
            let prompt = AppleScriptAdministratorPrompt(requiresAdministratorPrivileges: false)
            try await BlockingWork.run { try prompt.run(shellCommand: "cd -P /; /bin/test -d .") }
            XCTAssertFalse(fixture.files.fileExists(at: marker),
                           "The production prompt must discard inherited \(poison) code before any shell starts")
            let inherited = ProcessInfo.processInfo.environment
            let control = try await BlockingWork.run {
                try CommandLinkFixture.run("/usr/bin/osascript",
                    arguments: ["-e", "do shell script \"cd -P /; /bin/test -d .\""], environment: inherited)
            }
            XCTAssertEqual(control.0, 0, control.1)
            XCTAssertTrue(fixture.files.fileExists(at: marker), "Forwarded poison must execute in the positive control")
        }
        for (name, value) in zip(names, saved) {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
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
        fixture.authorization.beforeRun = {
            try fixture.files.deleteFile(at: plist)
            XCTAssertEqual(mkfifo(plist, 0o600), 0)
            // Inspect the executable program before running it: an app-read tool is forbidden,
            // independently of whether a FIFO reader would complete on this particular host.
            let command = try XCTUnwrap(fixture.authorization.commands.last)
            XCTAssertFalse(command.contains("PlistBuddy"), "The privileged step must not read the app's FIFO plist")
            if command.contains("PlistBuddy") { throw CommandLinkError(message: "Forbidden privileged app read") }
        }
        let model = CommandLineSettingsModel(installer: fixture.installer())
        await model.perform(.uninstall)
        XCTAssertNil(model.error)
        XCTAssertEqual(fixture.authorization.calls, 1)
        XCTAssertFalse(try fixture.files.entryExistsWithoutFollowingLinks(at: fixture.path))
    }
}

extension CommandLinkInstallerTests {
    func assertPromptPreservesOtherErrors() async throws {
        for message in ["User canceled. (-128)", "Von Benutzer:in abgebrochen. (-128)"] {
            let error = AppleScriptAdministratorPrompt.failure(status: 1, message: "0:1: execution error: " + message)
            XCTAssertEqual(error.code, -128, "Cancellation is identified by the final error number in every language")
        }
        for (message, expected) in [("User canceled. (128)", "User canceled."),
                                    ("User canceled. (-128) (1)", "User canceled. (-128)"),
                                    ("The link target changed. (1)", "The link target changed.")] {
            let error = AppleScriptAdministratorPrompt.failure(status: 1, message: "0:2927: execution error: " + message)
            XCTAssertEqual(error.code, 1, "A shell failure cannot forge cancellation")
            XCTAssertEqual(error.localizedDescription, expected)
        }
        XCTAssertEqual(AppleScriptAdministratorPrompt.failure(status: 9, message: "").localizedDescription,
                       "The administrator command failed.")
        let prompt = AppleScriptAdministratorPrompt(requiresAdministratorPrivileges: false)
        do {
            try await BlockingWork.run { try prompt.run(shellCommand: "printf '%s' 'fixture failure' >&2; exit 7") }
            XCTFail("A failed shell command must be reported")
        } catch {
            XCTAssertEqual(error.localizedDescription, "fixture failure")
            XCTAssertNotEqual((error as NSError).code, -128)
        }
    }
}
