import Darwin
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class CommandLineSetupTests: XCTestCase {
    func testRuntimeLaunchRepairsWritableDanglingLinkAndReportsPermissionFailure() async throws {
        for writable in [true, false] {
            let fixture = try CLILibraryFixture()
            let bin = fixture.paths.appSupportDir + "/command-line/bin"
            defer { _ = chmod(bin, 0o755); fixture.stop() }
            let path = bin + "/pensieve"
            let removed = fixture.root + "/Work.app/Contents/Helpers/pensieve"
            try fixture.files.createSymlink(at: path, pointingTo: removed)
            if !writable { XCTAssertEqual(chmod(bin, 0o555), 0) }
            try await fixture.start()
            let expected: CommandLinkStatus = writable ? .installed(path) : .broken
            await TestWait.until(failureMessage: "Launch must settle the command link status") {
                fixture.runtime.commandLineSettings.status == expected
            }
            XCTAssertEqual(fixture.runtime.commandLineSettings.status, expected)
            XCTAssertEqual(try fixture.files.symlinkTarget(at: path), writable
                ? Bundle.main.bundlePath + "/Contents/Helpers/pensieve" : removed)
            XCTAssertNil(fixture.runtime.commandLineSettings.error)
        }
    }

    func testBuiltDoctorReportsChecksAndFailsOnlyTheBrokenItems() async throws {
        let fixture = try CLILibraryFixture()
        defer { fixture.stop() }
        try await fixture.start()
        let bin = fixture.root + "/bin"
        let executable = Bundle.main.bundlePath + "/Contents/Helpers/pensieve"
        try fixture.files.createSymlink(at: bin + "/pensieve", pointingTo: executable)
        try fixture.files.createSymlink(at: bin + "/git", pointingTo: "/usr/bin/git")
        let agents = ["claude", "grok", "cursor", "codex", "openclaw", "hermes"]
        for agent in agents {
            try fixture.files.createDirectory(at: fixture.root + "/home/." + agent + (agent == "cursor" ? "/rules" : "/skills"))
        }
        let healthy = try checks(await fixture.run(["doctor"], environment: ["PATH": bin]))
        XCTAssertEqual(Set(healthy.keys), Set(["socket", "app", "path", "git"] + agents.map { "agent:" + $0 }))
        for (name, row) in healthy { XCTAssertEqual(row["ok"], .bool(true), name) }
        let noTools = try checks(await fixture.run(["doctor"], exit: 1,
            environment: ["PATH": bin, "DEVELOPER_DIR": fixture.root + "/missing-tools"]))
        XCTAssertEqual(noTools["git"]?["ok"], .bool(false), "The system git stub is not installed developer tools")
        try await checkLinkOwnership(fixture, bin: bin)
        try await checkOptionalAgent(fixture, bin: bin)
        try await checkCursorApplication(fixture, bin: bin)
        try fixture.files.deleteFile(at: bin + "/git")
        try fixture.files.deleteDirectory(at: fixture.root + "/home/.codex/skills")
        try fixture.files.deleteFile(at: bin + "/pensieve")
        try fixture.files.createSymlink(at: bin + "/pensieve",
            pointingTo: fixture.root + "/Work.app/Contents/Helpers/pensieve")
        let broken = try checks(await fixture.run(["doctor"], exit: 1, environment: ["PATH": bin]))
        for name in ["git", "path"] { XCTAssertEqual(broken[name]?["ok"], .bool(false), name) }
        XCTAssertEqual(broken["agent:codex"]?["ok"], .bool(true), "The skills folder appears on the first sync")
        XCTAssertEqual(broken["app"]?["ok"], .bool(true))
        XCTAssertEqual(broken["socket"]?["ok"], .bool(true))
        guard case .string(let pathMessage) = broken["path"]?["message"] else { return XCTFail("Missing path diagnostic") }
        XCTAssertTrue(pathMessage.contains("broken link"))
        fixture.runtime.commandServer?.stop()
        fixture.runtime.commandServer = nil
        let unavailable = try checks(await fixture.run(["doctor"], exit: 1, environment: ["PATH": bin]))
        XCTAssertEqual(unavailable["app"]?["ok"], .bool(false))
        XCTAssertEqual(unavailable["socket"]?["ok"], .bool(false))
        let socket = CLIProtocol.socketPath(appSupport: fixture.paths.appSupportDir,
                                           bundleID: try XCTUnwrap(Bundle.main.bundleIdentifier))
        let other = try AppSocketServer(path: socket,
            handshake: CLIHandshake(bundlePath: fixture.root + "/Other.app", appVersion: "1"), fileService: fixture.files) { _ in
                XCTFail("doctor must only inspect the handshake")
                return .success(.null)
            }
        defer { other.stop() }
        let wrong = try checks(await fixture.run(["doctor"], exit: 1, environment: ["PATH": bin]))
        XCTAssertEqual(wrong["app"]?["ok"], .bool(false))
        XCTAssertEqual(wrong["socket"]?["ok"], .bool(true))
    }

    private func checkLinkOwnership(_ fixture: CLILibraryFixture, bin: String) async throws {
        let path = bin + "/pensieve"
        let app = fixture.root + "/Incomplete.app"
        try fixture.files.writeData(at: app + "/Contents/Info.plist",
                                   data: fixture.files.readData(at: Bundle.main.bundlePath + "/Contents/Info.plist"))
        for (target, isBroken) in [(app + "/Contents/Helpers/pensieve", true),
                                   (fixture.root + "/Work.app/Contents/Helpers/pensieve", true),
                                   (fixture.root + "//Work.app/Contents/Helpers/pensieve", false),
                                   (fixture.root + "/./Work.app/Contents/Helpers/pensieve", false),
                                   (fixture.root + "/gone/../Work.app/Contents/Helpers/pensieve", false),
                                   ("Work.app/Contents/Helpers/pensieve", false)] {
            try fixture.files.deleteFile(at: path)
            // POSIX preserves malformed spelling for the ownership boundary to reject.
            XCTAssertEqual(symlink(target, path), 0)
            let result = try checks(await fixture.run(["doctor"], exit: 1, environment: ["PATH": bin]))
            XCTAssertEqual(result["path"]?["ok"], .bool(false))
            guard case .string(let message) = result["path"]?["message"] else { return XCTFail("Missing path message") }
            XCTAssertEqual(message.contains("broken link"), isBroken, target)
        }
        try fixture.files.deleteFile(at: path)
        try fixture.files.createSymlink(at: path, pointingTo: Bundle.main.bundlePath + "/Contents/Helpers/pensieve")
    }

    private func checkOptionalAgent(_ fixture: CLILibraryFixture, bin: String) async throws {
        try fixture.files.deleteDirectory(at: fixture.root + "/home/.hermes")
        let uninstalled = try checks(await fixture.run(["doctor"], environment: ["PATH": bin]))
        XCTAssertEqual(uninstalled["agent:hermes"]?["ok"], .bool(true), "An uninstalled agent must not fail doctor")
        XCTAssertEqual(uninstalled["agent:hermes"]?["message"], .string("Not installed"))
        try fixture.files.createSymlink(at: bin + "/hermes", pointingTo: "/usr/bin/true")
        let cliInstalled = try checks(await fixture.run(["doctor"], environment: ["PATH": bin]))
        XCTAssertEqual(cliInstalled["agent:hermes"]?["ok"], .bool(true),
                       "A detected CLI may not have synced its skills folder yet")
        let skills = fixture.root + "/home/.hermes/skills"
        try fixture.files.createDirectory(at: skills)
        XCTAssertEqual(chmod(skills, 0), 0)
        defer { _ = chmod(skills, 0o755) }
        let unreadable = try checks(await fixture.run(["doctor"], exit: 1, environment: ["PATH": bin]))
        XCTAssertEqual(unreadable["agent:hermes"]?["ok"], .bool(false), "An unreadable installed agent folder must fail")
        XCTAssertEqual(chmod(skills, 0o755), 0)
    }

    private func checkCursorApplication(_ fixture: CLILibraryFixture, bin: String) async throws {
        try fixture.files.deleteDirectory(at: fixture.root + "/home/.cursor")
        let absent = try checks(await fixture.run(["doctor"], environment: ["PATH": bin]))
        XCTAssertEqual(absent["agent:cursor"]?["message"], .string("Not installed"),
                       "Host applications must not affect doctor fixtures")
        try fixture.files.createDirectory(at: fixture.root + "/home/Applications/Cursor.app")
        let installed = try checks(await fixture.run(["doctor"], environment: ["PATH": bin]))
        XCTAssertEqual(installed["agent:cursor"]?["ok"], .bool(true))
        XCTAssertEqual(installed["agent:cursor"]?["message"], .string("Installed; its skills folder appears on the first sync."))
    }

    private func checks(_ envelope: CLIEnvelope) throws -> [String: [String: CLIValue]] {
        guard case .object(let data) = envelope.data, case .array(let rows) = data["checks"] else {
            XCTFail("doctor must return its checks in the JSON envelope")
            throw CocoaError(.coderReadCorrupt)
        }
        return try Dictionary(uniqueKeysWithValues: rows.map { value in
            guard case .object(let row) = value, case .string(let name) = row["check"],
                  case .string(let hint) = row["hint"] else {
                XCTFail("Each doctor check must include its name and a hint")
                throw CocoaError(.coderReadCorrupt)
            }
            XCTAssertFalse(hint.isEmpty, "The hint for \(name) must not be empty")
            return (name, row)
        })
    }
}
