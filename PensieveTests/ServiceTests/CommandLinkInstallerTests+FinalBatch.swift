import Darwin
import XCTest
@testable import Pensieve

extension CommandLinkInstallerTests {
    func assertUnicodeArgumentsAndMissingParents() async throws {
        let fixture = try CommandLinkFixture()
        defer { fixture.clean() }
        let target = fixture.root + "/Café ' \" \n/PensieveMoved.app/Contents/Helpers/pensieve"
        try fixture.files.createDirectory(at: fixture.directory)
        XCTAssertEqual(symlink(target, fixture.path), 0)
        XCTAssertEqual(Data(try fixture.files.symlinkTarget(at: fixture.path).utf8), Data(target.utf8),
                       "The fixture must hold the exact precomposed target bytes")
        let model = CommandLineSettingsModel(installer: fixture.installer())
        await model.perform(.uninstall)
        XCTAssertNil(model.error, "Uninstall must preserve precomposed UTF-8 bytes across AppleScript")
        XCTAssertFalse(try fixture.files.entryExistsWithoutFollowingLinks(at: fixture.path))
        try fixture.files.deleteDirectory(at: fixture.root + "/local")
        await model.perform(.install)
        XCTAssertNil(model.error, "Install must create a missing local parent under its admitted ancestor")
        XCTAssertTrue(fixture.files.directoryExists(at: fixture.directory))
        if fixture.files.directoryExists(at: fixture.directory) {
            for folder in [fixture.root + "/local", fixture.directory] {
                let mode = try CommandLinkFixture.run("/usr/bin/stat", arguments: ["-f", "%Lp:%u", folder])
                XCTAssertEqual(mode.1, "755:\(getuid())\n")
            }
        }
    }

    func assertRootRejectsInvalidArguments() async throws {
        let fixture = try CommandLinkFixture()
        defer { fixture.clean() }
        for executable in [fixture.root + "/pensieve", "Relative.app/Contents/Helpers/pensieve"] {
            let request = CommandLinkRequest(action: .install, directory: fixture.directory,
                executable: executable, user: getuid(), expected: nil)
            XCTAssertThrowsError(try FixtureCommandAuthorization().run(request), "Root must require an absolute app helper")
            if try fixture.files.entryExistsWithoutFollowingLinks(at: fixture.path) {
                try fixture.files.deleteFile(at: fixture.path)
            }
        }
        let highDevice = CommandLinkEntry(kind: .symlink, owner: getuid(), device: Int32.min, inode: 123,
                                          target: fixture.removedExecutable)
        let highRequest = CommandLinkRequest(action: .uninstall, directory: fixture.directory,
            executable: fixture.executable, user: getuid(), expected: highDevice)
        let highCommand = try PrivilegedCommandLink.command(for: highRequest)
        let identity = "Symbolic Link:\(getuid()):2147483648:123"
        XCTAssertTrue(highCommand.contains(identity) || highCommand.contains(Data(identity.utf8).base64EncodedString()),
                      "Expected device numbers must use stat's unsigned representation")
        for occupied in [false, true] {
            if occupied { try fixture.link(to: fixture.removedExecutable) }
            let before = try fixture.files.commandLinkEntry(at: fixture.path)
            let folderBefore = try fixture.files.commandLinkEntry(at: fixture.directory)
            let request = CommandLinkRequest(action: .install, directory: fixture.directory,
                executable: fixture.executable, user: getuid(), expected: before)
            let command = try PrivilegedCommandLink.command(for: request)
            // Exercise the untrusted argument boundary, regardless of its transport encoding.
            let invalid = command.replacingOccurrences(of: "'install'", with: "'unexpected'")
                .replacingOccurrences(of: "'aW5zdGFsbA=='", with: "'dW5leHBlY3RlZA=='")
            XCTAssertNotEqual(invalid, command)
            let prompt = AppleScriptAdministratorPrompt(requiresAdministratorPrivileges: false)
            do {
                try await BlockingWork.run { try prompt.run(shellCommand: invalid) }
                XCTFail("Root must reject an action outside install, uninstall and repair")
            } catch { /* Refusal must preserve the inspected path and its folder below. */ }
            XCTAssertEqual(try fixture.files.commandLinkEntry(at: fixture.path), before, "Invalid actions cannot change the leaf")
            XCTAssertEqual(try fixture.files.commandLinkEntry(at: fixture.directory), folderBefore,
                           "Invalid actions cannot create a command folder")
        }
    }
}

extension CommandLinkInstallerTests {
    func assertUnavailableBundleLocations() async throws {
        let fixture = try CommandLinkFixture()
        defer { fixture.clean() }
        for executable in ["/Volumes/Pensieve/Pensieve.app/Contents/Helpers/pensieve",
                           fixture.root + "/AppTranslocation/token/d/Pensieve.app/Contents/Helpers/pensieve"] {
            let installer = fixture.installer(executable: executable)
            let model = CommandLineSettingsModel(installer: installer)
            await model.perform(.install)
            XCTAssertEqual(model.error, "Move Pensieve to your Applications folder first.")
            if try fixture.files.entryExistsWithoutFollowingLinks(at: fixture.path) {
                try fixture.files.deleteFile(at: fixture.path)
            }
            try fixture.link(to: fixture.removedExecutable)
            XCTAssertThrowsError(try installer.repairAtLaunch())
            XCTAssertEqual(try fixture.files.symlinkTarget(at: fixture.path), fixture.removedExecutable)
            try fixture.files.deleteFile(at: fixture.path)
        }
        XCTAssertEqual(fixture.authorization.calls, 0, "A temporary app location must refuse before prompting")
    }

    func assertUnreadablePlistIsOccupied() async throws {
        let fixture = try CommandLinkFixture()
        defer { fixture.clean() }
        let app = fixture.root + "/PensieveNoInfo.app"
        try fixture.files.createDirectory(at: app + "/Contents")
        try fixture.link(to: app + "/Contents/Helpers/pensieve")
        let model = CommandLineSettingsModel(installer: fixture.installer())
        for unreadable in [false, true] {
            if unreadable {
                try fixture.files.writeFile(at: app + "/Contents/Info.plist", content: "unreadable")
                XCTAssertEqual(chmod(app + "/Contents/Info.plist", 0), 0)
            }
            await model.refresh()
            XCTAssertNil(model.error, "An unreadable identity is an occupied path, not an unavailable Settings page")
            if case .occupied = model.status {} else { XCTFail("Unproven apps must be occupied") }
        }
        _ = chmod(app + "/Contents/Info.plist", 0o600)
    }
}

/// Records the scheduling of real installer reads without replacing their filesystem behavior.
struct SettingsCheckingInstaller: CommandLinkInstalling {
    let base: CommandLinkInstaller
    func status() throws -> CommandLinkStatus {
        XCTAssertFalse(Thread.isMainThread, "Focus refresh must check command links off the main actor")
        return try base.status()
    }
    func perform(_ action: CommandLinkAction) throws { try base.perform(action) }
    func repairAtLaunch() throws { try base.repairAtLaunch() }
}

extension CommandLinkInstallerTests {
    func assertPromptConfiguration() throws {
        let fixture = try CommandLinkFixture()
        defer { fixture.clean() }
        let saved = try XCTUnwrap(getcwd(nil, 0))
        defer { free(saved) }
        XCTAssertEqual(chdir(fixture.root), 0)
        defer { XCTAssertEqual(chdir(saved), 0) }
        for (action, verb) in [(CommandLinkAction.install, "install"), (.uninstall, "uninstall"), (.repair, "repair")] {
            let process = AppleScriptAdministratorPrompt().makeProcess(shellCommand: "true", action: action)
            let script = try XCTUnwrap(process.arguments?.last)
            XCTAssertTrue(script.contains("with prompt \"Pensieve wants to \(verb) the pensieve command.\""),
                          "Every administrator dialog must name Pensieve and the action")
            XCTAssertTrue(script.contains("with administrator privileges"))
            XCTAssertEqual(process.currentDirectoryURL?.path, "/", "The prompt child must start at the filesystem root")
            XCTAssertEqual((process.standardInput as? FileHandle)?.fileDescriptor, FileHandle.nullDevice.fileDescriptor,
                           "The prompt child must not inherit stdin")
        }
    }
}
