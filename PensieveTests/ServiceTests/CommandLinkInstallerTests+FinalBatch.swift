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
        let app = fixture.root + "/Other.app"
        try fixture.files.writeExecutableFile(at: app + "/Contents/Helpers/pensieve", content: "#!/bin/sh\nexit 0\n")
        try fixture.link(to: app + "/Contents/Helpers/pensieve")
        let model = CommandLineSettingsModel(installer: fixture.installer())
        for identity in ["missing", "foreign", "symlink", "unreadable"] {
            let plist = app + "/Contents/Info.plist"
            if try fixture.files.entryExistsWithoutFollowingLinks(at: plist) { try fixture.files.deleteFile(at: plist) }
            if identity == "foreign" {
                let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.other"],
                                                              format: .xml, options: 0)
                try fixture.files.writeData(at: plist, data: data)
            } else if identity == "symlink" {
                try fixture.files.createSymlink(at: plist, pointingTo: Bundle.main.bundlePath + "/Contents/Info.plist")
            } else if identity == "unreadable" {
                try fixture.files.writeFile(at: plist, content: "unreadable")
                XCTAssertEqual(chmod(plist, 0), 0)
            }
            let before = try fixture.files.commandLinkEntry(at: fixture.path)
            await model.refresh()
            XCTAssertNil(model.error, "An unproven identity is an occupied path, not an unavailable Settings page")
            if case .occupied = model.status {} else { XCTFail("Unproven apps must be occupied: \(identity)") }
            for action in [CommandLinkAction.install, .uninstall, .repair] {
                await model.perform(action)
                XCTAssertNotNil(model.error, "Unproven apps must refuse \(action): \(identity)")
                XCTAssertEqual(try fixture.files.commandLinkEntry(at: fixture.path), before)
            }
            XCTAssertEqual(fixture.authorization.calls, 0, "Unproven apps must refuse before authorization: \(identity)")
            if identity == "unreadable" { XCTAssertEqual(chmod(plist, 0o600), 0) }
        }
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

extension CommandLinkInstallerTests {
    func assertReplacementAfterLeafReadSurvives() throws {
        for action in [CommandLinkAction.install, .uninstall, .repair] {
            for scenario in [(false, false, false), (false, true, false), (true, false, false), (true, true, false),
                             (false, false, true), (false, true, true), (true, false, true), (true, true, true)]
                where (!scenario.0 && !scenario.2) || action == .repair {
                let (launch, brew, liveReplacement) = scenario
                let fixture = try CommandLinkFixture()
                defer { fixture.clean() }
                if action != .install {
                    try fixture.link(to: action == .repair || brew ? fixture.removedExecutable : fixture.executable)
                }
                var replacement: CommandLinkEntry?
                let files = LeafReadSwappingFileService(path: fixture.path) {
                    if try fixture.files.entryExistsWithoutFollowingLinks(at: fixture.path) {
                        try fixture.files.deleteFile(at: fixture.path)
                    }
                    try fixture.link(to: liveReplacement ? fixture.executable
                        : fixture.root + "/Replacement.app/Contents/Helpers/pensieve")
                    replacement = try fixture.files.commandLinkEntry(at: fixture.path)
                }
                if brew { try fixture.files.createDirectory(at: fixture.root + "/local/Caskroom/pensieve") }
                let installer = fixture.installer(homebrew: brew ? [fixture.directory] : [], files: files)
                if launch { XCTAssertThrowsError(try installer.repairAtLaunch()) } else {
                    XCTAssertThrowsError(try installer.perform(action), "A replacement after the check must refuse")
                }
                XCTAssertEqual(fixture.authorization.calls, launch ? 0 : 1,
                               "The captured entry must decide whether authorization is needed")
                XCTAssertNotNil(replacement, "The fixture must swap immediately after the first leaf read")
                XCTAssertEqual(try fixture.files.commandLinkEntry(at: fixture.path), replacement,
                               "A replacement after the check must survive \(action), launch=\(launch)")
            }
        }
    }

    func assertRenamedAppsCanBeUninstalled() async throws {
        for identifier in ["com.jaredatch.Pensieve", "com.jaredatch.Pensieve.debug",
                           "com.jaredatch.Pensieve.dogfood", "own-helper"] {
            let fixture = try CommandLinkFixture()
            defer { fixture.clean() }
            let app = fixture.root + "/Work.app"
            let helper = app + "/Contents/Helpers/pensieve"
            try fixture.files.writeExecutableFile(at: helper, content: "#!/bin/sh\nexit 0\n")
            if identifier != "own-helper" {
                let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier],
                                                              format: .xml, options: 0)
                try fixture.files.writeData(at: app + "/Contents/Info.plist", data: data)
            }
            let installed = CommandLineSettingsModel(installer: fixture.installer(executable: helper))
            await installed.perform(.install)
            XCTAssertNil(installed.error)
            XCTAssertEqual(installed.status, .installed(fixture.path), "A renamed running app owns its helper")
            let model = identifier == "own-helper" ? installed : CommandLineSettingsModel(installer: fixture.installer())
            await model.refresh()
            XCTAssertEqual(model.status, .installed(fixture.path), "Bundle identity must admit a renamed Pensieve app")
            if identifier == "own-helper" {
                let expected = try fixture.files.commandLinkEntry(at: fixture.path)
                let request = CommandLinkRequest(action: .uninstall, directory: fixture.directory,
                    executable: helper, user: getuid(), expected: expected)
                XCTAssertNoThrow(try fixture.files.changeCommandLink(request), "The write recheck must recognize our own helper")
                if try !fixture.files.entryExistsWithoutFollowingLinks(at: fixture.path) { try fixture.link(to: helper) }
                try fixture.files.createDirectory(at: fixture.root + "/local/Caskroom/pensieve")
                XCTAssertEqual(try fixture.installer(homebrew: [fixture.directory], executable: helper).status(),
                               .homebrew(fixture.path), "Homebrew must recognize our own helper without a plist")
                try fixture.files.deleteDirectory(at: fixture.root + "/local/Caskroom")
            }
            await model.perform(.uninstall)
            XCTAssertNil(model.error, "A renamed Pensieve app must be uninstallable")
            XCTAssertFalse(try fixture.files.entryExistsWithoutFollowingLinks(at: fixture.path))
            try fixture.files.deleteDirectory(at: app)
            try fixture.link(to: helper)
            let moved = CommandLineSettingsModel(installer: fixture.installer())
            await moved.refresh()
            XCTAssertEqual(moved.status, .broken, "A renamed app remains ours after it disappears")
            await moved.perform(.uninstall)
            XCTAssertNil(moved.error, "A renamed missing app must be uninstallable")
            XCTAssertFalse(try fixture.files.entryExistsWithoutFollowingLinks(at: fixture.path))
        }
    }
}

extension CommandLinkInstallerTests {
    func assertStatusUsesCapturedLeaf() throws {
        for brew in [false, true] {
            for captured in ["absent", "installed", "broken", "occupied"] {
                let fixture = try CommandLinkFixture()
                defer { fixture.clean() }
                if brew { try fixture.files.createDirectory(at: fixture.root + "/local/Caskroom/pensieve") }
                let target = captured == "installed" ? fixture.executable : fixture.removedExecutable
                if captured == "occupied" {
                    try fixture.files.writeFile(at: fixture.path, content: "foreign")
                } else if captured != "absent" { try fixture.link(to: target) }
                let files = LeafReadSwappingFileService(path: fixture.path) {
                    if try fixture.files.entryExistsWithoutFollowingLinks(at: fixture.path) {
                        try fixture.files.deleteFile(at: fixture.path)
                    }
                    try fixture.link(to: captured == "installed" ? fixture.removedExecutable : fixture.executable)
                }
                let status = try fixture.installer(homebrew: brew ? [fixture.directory] : [], files: files).status()
                switch captured {
                case "absent": XCTAssertEqual(status, .absent, "Status must keep the captured absent leaf")
                case "installed": XCTAssertEqual(status, brew ? .homebrew(fixture.path) : .installed(fixture.path),
                                                   "Executability must come from the captured target")
                case "broken": XCTAssertEqual(status, .broken, "A replacement cannot hide the captured broken link")
                default: XCTAssertEqual(status, .occupied("\(fixture.path) is taken by another file"),
                                        "Homebrew cannot hide the captured foreign file")
                }
                XCTAssertNil(files.afterRead, "The fixture must swap after the captured read")
            }
        }
    }
}
