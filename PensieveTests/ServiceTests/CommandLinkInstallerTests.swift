import Darwin
import XCTest
@testable import Pensieve

@MainActor
final class CommandLinkInstallerTests: XCTestCase {
    func testInstallCreatesFolderAndNewShellRunsBundledVersionThenUninstalls() async throws {
        let fixture = try CommandLinkFixture()
        defer { fixture.clean() }
        let model = CommandLineSettingsModel(installer: fixture.installer())
        model.refresh()
        XCTAssertEqual(model.status, .absent)
        await model.perform(.install)
        XCTAssertTrue(fixture.authorization.commands.allSatisfy { $0.hasPrefix("'/bin/sh' ") },
                      "Root must start the protected system shell, never the bundle helper")
        XCTAssertEqual(fixture.authorization.promptThreads, [true], "The administrator prompt must run on the main thread")

        XCTAssertNil(model.error)
        XCTAssertEqual(model.status, .installed(fixture.path))
        XCTAssertEqual(try fixture.files.symlinkTarget(at: fixture.path), fixture.executable)
        XCTAssertEqual(fixture.authorization.calls, 1)
        let folderMode = try CommandLinkFixture.run("/usr/bin/stat", arguments: ["-f", "%Lp:%u", fixture.directory])
        XCTAssertEqual(folderMode.1, "755:\(getuid())\n", "New bin must have mode 0755 despite the runner's restrictive umask")
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = fixture.directory
        environment["HOME"] = fixture.root
        environment["CFFIXED_USER_HOME"] = fixture.root
        let result = try await BlockingWork.run {
            try CommandLinkFixture.run("/bin/zsh", arguments: ["-f", "-c", "pensieve --version"], environment: environment)
        }
        XCTAssertEqual(result.0, 0, result.1)
        let version = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        XCTAssertEqual(result.1, "pensieve \(version)\n")
        await model.perform(.uninstall)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.status, .absent)
        XCTAssertFalse(try fixture.files.entryExistsWithoutFollowingLinks(at: fixture.path))
        let hiddenRequest = CommandLinkRequest(action: .install, directory: fixture.directory,
            executable: "/bin/sh", user: getuid(), expected: nil)
        let encoded = try JSONEncoder().encode(hiddenRequest).base64EncodedString()
        let hidden = try await BlockingWork.run {
            try CommandLinkFixture.run(fixture.executable, arguments: ["--manage-command-link", encoded],
                                       environment: environment)
        }
        XCTAssertEqual(hidden.0, 64, "The CLI must reject the retired link-changing entry point")
        XCTAssertFalse(try fixture.files.entryExistsWithoutFollowingLinks(at: fixture.path),
                       "CLI arguments must never create links")
    }

    func testCancelledInstallChangesNothingAndFailedCreationKeepsNewFolder() async throws {
        let fixture = try CommandLinkFixture()
        defer { fixture.clean() }
        fixture.authorization.cancelled = true
        let model = CommandLineSettingsModel(installer: fixture.installer())
        await model.perform(.install)
        XCTAssertEqual(fixture.authorization.calls, 1)
        XCTAssertEqual(model.status, .absent)
        XCTAssertNil(model.error)
        XCTAssertFalse(fixture.files.directoryExists(at: fixture.directory))
        fixture.authorization.cancelled = false
        let failure = CommandLineSettingsModel(installer: fixture.installer(executable: String(repeating: "a", count: 5000)))
        await failure.perform(.install)
        XCTAssertNotNil(failure.error)
        XCTAssertTrue(failure.error?.contains("link wasn't made") == true)
        XCTAssertTrue(fixture.files.directoryExists(at: fixture.directory))
        XCTAssertFalse(try fixture.files.entryExistsWithoutFollowingLinks(at: fixture.path))
    }

    func testForeignFilesAndLinksRefuseInstallAndUninstallWithoutAuthorization() async throws {
        let fixture = try CommandLinkFixture()
        defer { fixture.clean() }
        for target in [nil, Optional(fixture.root + "/foreign")] {
            if let target { try fixture.link(to: target) } else {
                try fixture.files.writeFile(at: fixture.path, content: "foreign")
            }
            let before = try fixture.files.commandLinkEntry(at: fixture.path)
            let model = CommandLineSettingsModel(installer: fixture.installer())
            for action in [CommandLinkAction.install, .uninstall] {
                await model.perform(action)
                XCTAssertNotNil(model.error)
                if case .occupied(let message) = model.status {
                    XCTAssertTrue(message.contains(target == nil ? "another file" : "link to"))
                } else { XCTFail("Foreign entries must be reported as occupied") }
                XCTAssertEqual(try fixture.files.commandLinkEntry(at: fixture.path), before)
            }
            for action in [CommandLinkAction.install, .uninstall, .repair] {
                let request = CommandLinkRequest(action: action, directory: fixture.directory,
                    executable: fixture.executable, user: getuid(), expected: before)
                XCTAssertThrowsError(try FixtureCommandAuthorization().run(request))
                XCTAssertEqual(try fixture.files.commandLinkEntry(at: fixture.path), before)
            }
            try fixture.files.deleteFile(at: fixture.path)
        }
        XCTAssertEqual(fixture.authorization.calls, 0)
    }

    func testChangesDuringAuthorizationPreserveTheReplacementForEachAction() async throws {
        for action in [CommandLinkAction.install, .uninstall, .repair] {
            for replacement in ["file", "foreign-link", "owned-link"] {
                let fixture = try CommandLinkFixture()
                defer { fixture.clean() }
                if action != .install {
                    try fixture.link(to: action == .repair ? fixture.removedExecutable : fixture.executable)
                }
                var replacementEntry: CommandLinkEntry?
                fixture.authorization.beforeRun = {
                    if try fixture.files.entryExistsWithoutFollowingLinks(at: fixture.path) {
                        try fixture.files.deleteFile(at: fixture.path)
                    }
                    if replacement == "file" { try fixture.files.writeFile(at: fixture.path, content: "replacement") } else {
                        try fixture.link(to: replacement == "owned-link" ? fixture.executable : fixture.root + "/foreign")
                    }
                    replacementEntry = try fixture.files.commandLinkEntry(at: fixture.path)
                }
                let model = CommandLineSettingsModel(installer: fixture.installer())
                await model.perform(action)
                XCTAssertNotNil(model.error, "\(action) must report the refused change")
                XCTAssertEqual(fixture.authorization.calls, 1)
                XCTAssertEqual(try fixture.files.commandLinkEntry(at: fixture.path), replacementEntry)
                if replacement == "file" { XCTAssertEqual(try fixture.files.readFile(at: fixture.path), "replacement") }
            }
        }
    }

    func testUnsafeParentsRefuseBeforeAuthorizationAndAreRecheckedByHelper() async throws {
        for parent in ["local", "local/bin"] {
            let fixture = try CommandLinkFixture()
            defer { fixture.clean() }
            let actual = fixture.root + "/actual"
            try fixture.files.createDirectory(at: actual)
            if parent == "local" { try fixture.files.deleteDirectory(at: fixture.root + "/local") }
            try fixture.files.createSymlink(at: fixture.root + "/" + parent, pointingTo: actual)
            let model = CommandLineSettingsModel(installer: fixture.installer())
            await model.perform(.install)
            XCTAssertEqual(fixture.authorization.calls, 0)
            XCTAssertNotNil(model.error)
            XCTAssertEqual(try fixture.files.listDirectory(at: actual), [])
            let request = CommandLinkRequest(action: .install, directory: fixture.directory,
                executable: fixture.executable, user: getuid(), expected: nil)
            XCTAssertThrowsError(try FixtureCommandAuthorization().run(request))
            XCTAssertEqual(try fixture.files.listDirectory(at: actual), [], "Privileged parent admission must refuse symlinks")
        }
        let fixture = try CommandLinkFixture()
        defer { fixture.clean() }
        // The real on-disk owner is foreign to this injected requesting UID; no chown or elevation.
        let foreign = CommandLineSettingsModel(installer: fixture.installer(user: getuid() + 1))
        await foreign.perform(.install)
        XCTAssertEqual(fixture.authorization.calls, 0)
        XCTAssertNotNil(foreign.error)
        let foreignRequest = CommandLinkRequest(action: .install, directory: fixture.directory,
            executable: fixture.executable, user: getuid() + 1, expected: nil)
        XCTAssertThrowsError(try FixtureCommandAuthorization().run(foreignRequest))
        XCTAssertFalse(fixture.files.directoryExists(at: fixture.directory))
        fixture.authorization.beforeRun = {
            try fixture.files.createDirectory(at: fixture.root + "/elsewhere")
            try fixture.files.createSymlink(at: fixture.directory, pointingTo: fixture.root + "/elsewhere")
        }
        let changed = CommandLineSettingsModel(installer: fixture.installer())
        await changed.perform(.install)
        XCTAssertEqual(fixture.authorization.calls, 1)
        XCTAssertNotNil(changed.error)
        XCTAssertEqual(try fixture.files.listDirectory(at: fixture.root + "/elsewhere"), [])
    }

    func testHomebrewIsInstalledWithoutOfferingOrCreatingAnotherLink() async throws {
        let fixture = try CommandLinkFixture()
        defer { fixture.clean() }
        let brew = fixture.root + "/homebrew"
        try fixture.files.createDirectory(at: brew + "/Caskroom/pensieve")
        try fixture.files.createSymlink(at: brew + "/bin/pensieve", pointingTo: fixture.executable)
        let model = CommandLineSettingsModel(installer: fixture.installer(homebrew: [brew + "/bin"]))
        model.refresh()
        XCTAssertEqual(model.status, .homebrew(brew + "/bin/pensieve"))
        XCTAssertNil(model.status.action)
        await model.perform(.install)
        XCTAssertNil(model.error)
        XCTAssertEqual(fixture.authorization.calls, 0)
        XCTAssertFalse(try fixture.files.entryExistsWithoutFollowingLinks(at: fixture.path))
    }

    func testRepairUsesAuthorizationAndRefusesAStillExistingApp() async throws {
        let fixture = try CommandLinkFixture()
        defer { fixture.clean() }
        try fixture.link(to: fixture.removedExecutable)
        let model = CommandLineSettingsModel(installer: fixture.installer())
        model.refresh()
        XCTAssertEqual(model.status, .broken)
        await model.perform(.repair)
        XCTAssertNil(model.error)
        XCTAssertEqual(fixture.authorization.calls, 1)
        XCTAssertEqual(try fixture.files.symlinkTarget(at: fixture.path), fixture.executable)
        try fixture.files.deleteFile(at: fixture.path)
        let incompleteApp = fixture.root + "/PensieveIncomplete.app"
        try fixture.files.createDirectory(at: incompleteApp + "/Contents")
        let info = try fixture.files.readData(at: Bundle.main.bundlePath + "/Contents/Info.plist")
        try fixture.files.writeData(at: incompleteApp + "/Contents/Info.plist", data: info)
        try fixture.link(to: incompleteApp + "/Contents/Helpers/pensieve")
        let before = try fixture.files.commandLinkEntry(at: fixture.path)
        await model.perform(.repair)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(fixture.authorization.calls, 1)
        XCTAssertEqual(try fixture.files.commandLinkEntry(at: fixture.path), before)
        let request = CommandLinkRequest(action: .repair, directory: fixture.directory,
            executable: fixture.executable, user: getuid(), expected: before)
        XCTAssertThrowsError(try FixtureCommandAuthorization().run(request))
        XCTAssertEqual(try fixture.files.commandLinkEntry(at: fixture.path), before)
    }
}
