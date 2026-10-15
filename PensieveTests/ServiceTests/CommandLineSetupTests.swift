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
            let removed = fixture.root + "/PensieveMoved.app/Contents/Helpers/pensieve"
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
        try fixture.files.deleteFile(at: bin + "/git")
        try fixture.files.deleteDirectory(at: fixture.root + "/home/.codex/skills")
        try fixture.files.deleteFile(at: bin + "/pensieve")
        try fixture.files.createSymlink(at: bin + "/pensieve",
            pointingTo: fixture.root + "/PensieveGone.app/Contents/Helpers/pensieve")
        let broken = try checks(await fixture.run(["doctor"], exit: 1, environment: ["PATH": bin]))
        for name in ["git", "agent:codex", "path"] { XCTAssertEqual(broken[name]?["ok"], .bool(false), name) }
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
