import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class SyncLogCommandTests: XCTestCase {
    func testRuntimeBuiltSyncAndWindowFollowTheLink() async throws {
        let h = try SyncLogCommandFixture()
        defer { try? h.disk.remove() }
        try await seedStuckStore(h.disk)
        let paths = h.disk.paths
        let coordinator = SyncCoordinator(modelContainer: h.container)
        let suite = "SyncLogCommand-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        await paths.configureCoordinator(coordinator, defaults: defaults)
        let model = paths.makeConflictResolutionModel(onResolutionStarted: { { _ in } })
        let helper = Bundle.main.bundlePath + "/Contents/Helpers/pensieve"
        let sentence = SyncLogCommandFixture.sentence(helper)
        h.assertMessage(SyncLogCommandFixture.message(await coordinator.runCycle()), endsWith: sentence)
        await model.loadAndReport(container: h.container)
        h.assertMessage(SyncLogCommandFixture.message(model), endsWith: sentence)
        await paths.syncSteps.waitUntilIdle()
        let link = paths.appSupportDir + "/command-line/bin/pensieve"
        try h.disk.files.createDirectory(at: paths.appSupportDir + "/command-line/bin")
        try h.disk.files.createSymlink(at: link, pointingTo: helper)
        h.assertMessage(SyncLogCommandFixture.message(await coordinator.runCycle()),
                        endsWith: SyncLogCommandFixture.shortSentence)
        await model.loadAndReport(container: h.container)
        h.assertMessage(SyncLogCommandFixture.message(model), endsWith: SyncLogCommandFixture.shortSentence)
        let settings = paths.makeCommandLineSettings()
        await settings.refresh()
        XCTAssertEqual(settings.status, .installed(link))
    }

    func testUnlinkedCommandGetsThisAppsFullPath() async throws {
        let h = try SyncLogCommandFixture(), link = try CommandLinkFixture()
        defer { try? h.disk.remove(); link.clean() }
        let sentence = SyncLogCommandFixture.sentence(link.executable)
        for route in SyncLogCommandFixture.Route.allCases {
            h.assertMessage(await h.message(route, installer: link.installer()), endsWith: sentence)
        }
        // No installer means no filesystem inspection and the same app's bundled helper.
        h.assertMessage(await h.message(.cycleAbort, installer: nil), endsWith: sentence)
        h.assertMessage(await h.message(.windowReturn, installer: nil), endsWith: sentence)
        try link.files.createDirectory(at: link.directory)
        try link.link(to: link.removedExecutable)
        XCTAssertEqual(try link.installer().status(), .broken)
        h.assertMessage(await h.message(.cycleAbort, installer: link.installer()), endsWith: sentence)
        try link.files.deleteFile(at: link.path)
        try link.files.writeFile(at: link.path, content: "foreign command")
        XCTAssertTrue(try link.installer().status().hasProblem)
        h.assertMessage(await h.message(.cycleAbort, installer: link.installer()), endsWith: sentence)
        try link.files.deleteFile(at: link.path)
        try link.link(to: link.removedExecutable)
        let brew = try makeHomebrew(link)
        let mixed = link.installer(homebrew: [brew])
        XCTAssertEqual(try mixed.status(), .alongsideHomebrew(.broken, brew + "/pensieve"))
        h.assertMessage(await h.message(.cycleAbort, installer: mixed), endsWith: sentence)
        // A non-directory ancestor makes the real installer's lstat fail with ENOTDIR.
        let obstructed = link.root + "/not-a-directory"
        try link.files.writeFile(at: obstructed, content: "file")
        let unreadable = CommandLinkInstaller(files: link.files, directory: obstructed + "/bin",
            executable: link.executable, user: getuid(), homebrewDirectories: [],
            authorization: AdminCommandLinkAuthorization(prompt: link.authorization))
        XCTAssertThrowsError(try unreadable.status())
        h.assertMessage(await h.message(.cycleAbort, installer: unreadable), endsWith: sentence)
    }

    func testLinkedCommandKeepsTheShortForm() async throws {
        for kind in 0..<3 {
            let h = try SyncLogCommandFixture(), link = try CommandLinkFixture()
            defer { try? h.disk.remove(); link.clean() }
            let brew = link.root + "/brew/bin"
            let installer = link.installer(homebrew: kind == 0 ? [] : [brew])
            let routes: [SyncLogCommandFixture.Route] = [.cycleAbort, .cycleReturn, .windowAbort, .windowReturn]
            for route in routes {
                h.assertMessage(await h.message(route, installer: installer),
                                endsWith: SyncLogCommandFixture.sentence(link.executable))
            }
            if kind != 1 { try await BlockingWork.run { try installer.perform(.install) } }
            if kind != 0 { _ = try makeHomebrew(link) }
            if kind == 0 { XCTAssertEqual(try installer.status(), .installed(link.path)) }
            if kind == 1 { XCTAssertEqual(try installer.status(), .homebrew(brew + "/pensieve")) }
            if kind == 2 {
                XCTAssertEqual(try installer.status(), .alongsideHomebrew(.installed(link.path), brew + "/pensieve"))
            }
            for route in routes {
                let message = await h.message(route, installer: installer)
                h.assertMessage(message, endsWith: SyncLogCommandFixture.shortSentence)
                XCTAssertFalse(message.contains(link.executable), message)
            }
        }
    }

    func testFullPathLineRunsWhenPasted() async throws {
        let h = try SyncLogCommandFixture(), link = try CommandLinkFixture()
        defer { try? h.disk.remove(); link.clean() }
        let executable = try helperAlias(link, folder: "App space ' \" $(false)")
        let message = await h.message(.cycleReturn, installer: link.installer(executable: executable))
        let text = h.statusText(message)
        h.assertMessage(text, endsWith: SyncLogCommandFixture.sentence(executable, quoted: true))
        await h.assertRuns(text)
    }

    func testPathDisplayCleanupWouldChangeKeepsTheShortForm() async throws {
        let h = try SyncLogCommandFixture(), link = try CommandLinkFixture()
        defer { try? h.disk.remove(); link.clean() }
        for folder in ["App space", "App\u{200B}name", "App\u{202E}name", "App\tname"] {
            let executable = try helperAlias(link, folder: folder)
            let installer = link.installer(executable: executable)
            let sentence = folder == "App space" ? SyncLogCommandFixture.sentence(executable, quoted: true)
                : SyncLogCommandFixture.shortSentence
            let text = h.statusText(await h.message(.cycleReturn, installer: installer))
            h.assertMessage(text, endsWith: sentence)
            let window = await h.message(.windowReturn, installer: installer)
            h.assertMessage(window, endsWith: sentence)
            if folder != "App space" {
                XCTAssertFalse(text.contains(link.root), text)
                XCTAssertFalse(window.contains(link.root), window)
            }
        }
    }

    func makeHomebrew(_ link: CommandLinkFixture) throws -> String {
        let prefix = link.root + "/brew"
        try link.files.createDirectory(at: prefix + "/Caskroom/pensieve")
        try link.files.createDirectory(at: prefix + "/bin")
        try link.files.createSymlink(at: prefix + "/bin/pensieve", pointingTo: link.executable)
        return prefix + "/bin"
    }

    func helperAlias(_ link: CommandLinkFixture, folder: String) throws -> String {
        let directory = link.root + "/" + folder
        try link.files.createDirectory(at: directory)
        try link.files.createSymlink(at: directory + "/Pensieve.app", pointingTo: Bundle.main.bundlePath)
        return directory + "/Pensieve.app/Contents/Helpers/pensieve"
    }

    private func seedStuckStore(_ disk: GitFailureFixture) async throws {
        try await BlockingWork.run {
            try disk.seedRepository()
            let git = disk.paths.makeGitService()
            _ = try git.runOrThrow(["checkout", "-b", "peer"], in: disk.root)
            try disk.files.writeFile(at: disk.root + "/skills/example/SKILL.md", content: "peer\n")
            try git.stageAllAndCommit(at: disk.root, message: "peer changes")
            _ = try git.runOrThrow(["checkout", "main"], in: disk.root)
            try disk.files.writeFile(at: disk.root + "/skills/example/SKILL.md", content: "local\n")
            try git.stageAllAndCommit(at: disk.root, message: "local changes")
            XCTAssertThrowsError(try git.runOrThrow(["rebase", "peer"], in: disk.root))
            XCTAssertTrue(git.isRebaseInProgress(at: disk.root))
            try disk.files.writeFile(at: disk.root + "/.git/index.lock", content: "abandoned lock")
        }
    }
}
