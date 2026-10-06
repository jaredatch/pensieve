import XCTest
@testable import Pensieve

final class AgentDetectionServiceTests: XCTestCase {

    /// Host-independent stub: the service's real filesystem/PATH reads are fully replaced,
    /// so results depend only on what this stub is told is present (never on host installs).
    private struct StubProbe: EnvironmentProbe {
        var presentDirectories: Set<String> = []
        var presentFiles: Set<String> = []
        var presentExecutables: Set<String> = []

        func directoryExists(at path: String) -> Bool { presentDirectories.contains(path) }
        func fileExists(at path: String) -> Bool { presentFiles.contains(path) }
        func executableExists(named name: String) -> Bool { presentExecutables.contains(name) }
    }

    /// The same home the service composes with — stays in sync even under the throwaway
    /// HOME that script/test.sh exports, because both sides read NSHomeDirectory().
    private let home = NSHomeDirectory()

    func testOnlyOpenClawAndHermesPresent() {
        let probe = StubProbe(presentDirectories: [home + "/.openclaw", home + "/.hermes"])
        let service = AgentDetectionService(probe: probe)
        XCTAssertEqual(service.installedPlatforms(), [.openClaw, .hermes])
    }

    func testNonePresentReturnsEmpty() {
        let service = AgentDetectionService(probe: StubProbe())
        XCTAssertEqual(service.installedPlatforms(), [])
    }

    func testAllPresentReturnsEveryPlatform() {
        let probe = StubProbe(presentDirectories: [
            home + "/.claude", home + "/.grok", home + "/.cursor", home + "/.codex",
            home + "/.openclaw", home + "/.hermes"
        ])
        let service = AgentDetectionService(probe: probe)
        XCTAssertEqual(service.installedPlatforms(), PlatformTarget.allCases)
    }

    func testCLIOnlyCounts() {
        // Config dir absent, executable on PATH present → installed.
        let probe = StubProbe(presentExecutables: ["codex"])
        let service = AgentDetectionService(probe: probe)
        XCTAssertTrue(service.isInstalled(.codex))
        XCTAssertEqual(service.installedPlatforms(), [.codex])
    }

    func testGrokDetectedByDirectory() {
        let service = AgentDetectionService(
            probe: StubProbe(presentDirectories: [home + "/.grok"])
        )
        XCTAssertTrue(service.isInstalled(.grok))
        XCTAssertEqual(service.installedPlatforms(), [.grok])
    }

    func testGrokDetectedByExecutable() {
        let service = AgentDetectionService(
            probe: StubProbe(presentExecutables: ["grok"])
        )
        XCTAssertTrue(service.isInstalled(.grok))
        XCTAssertEqual(service.installedPlatforms(), [.grok])
    }

    func testGrokAbsentWhenNoSignal() {
        let service = AgentDetectionService(probe: StubProbe())
        XCTAssertFalse(service.isInstalled(.grok))
    }

    func testCursorDetectedViaAppBundle() {
        let probe = StubProbe(presentDirectories: ["/Applications/Cursor.app"])
        let service = AgentDetectionService(probe: probe)
        XCTAssertTrue(service.isInstalled(.cursor))
        XCTAssertEqual(service.installedPlatforms(), [.cursor])
    }

    func testSystemEnvironmentProbeRequiresExecutableBitForCLI() throws {
        let tempDir = TestTemporaryDirectory.path + "PensieveAgentDetectionTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let toolPath = tempDir + "/faketool"
        try "not executable".write(toFile: toolPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: toolPath)

        let probe = SystemEnvironmentProbe(fileService: FileService(), pathEntries: [tempDir])
        XCTAssertFalse(probe.executableExists(named: "faketool"))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: toolPath)
        XCTAssertTrue(probe.executableExists(named: "faketool"))
    }
}
