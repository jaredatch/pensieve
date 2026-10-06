import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class SyncAuditTests: XCTestCase {
    private var tempDir = ""

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.url
            .appendingPathComponent("pensieve-sync-audit-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if !tempDir.isEmpty {
            try? FileManager.default.removeItem(atPath: tempDir)
        }
    }

    func testStatusFileRoundTripsThroughDaemonCLI() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let container = try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let coordinator = await Task.detached { SyncCoordinator(modelContainer: container) }.value
        await coordinator.configure(
            engine: AuditHealthyEngine(),
            git: GitService(),
            credentials: AuditEmptyCredentialStore(),
            root: tempDir,
            audit: SyncAudit(appSupport: tempDir, now: { date }),
            machineIdentity: InertMachineIdentity(),
            machineStateService: InertMachineStateService(),
            now: { date }
        )
        _ = await Task.detached { await coordinator.runCycle() }.value

        let outcome = DaemonCLI.execute(
            ["status", "--json"],
            appSupport: tempDir,
            readFile: { try? Data(contentsOf: URL(fileURLWithPath: $0)) },
            runCycle: { .skipped(.noRemote) },
            now: { date }
        )

        XCTAssertEqual(outcome.exitCode, 0)
        let decoded = try JSONDecoder().decode(DaemonStatus.self, from: Data(outcome.stdout.utf8))
        XCTAssertEqual(decoded.result, "synced")
        XCTAssertEqual(decoded.detail, "upToDate")
    }

    func testLogLineAppended() throws {
        let audit = SyncAudit(
            appSupport: tempDir,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        audit.record(category: "synced", detail: "pushed")
        audit.record(category: "skipped", detail: "locked")

        let log = try String(contentsOfFile: tempDir + "/daemon.log", encoding: .utf8)
        XCTAssertEqual(log.split(separator: "\n").count, 2)
        XCTAssertTrue(log.contains("synced pushed"))
        XCTAssertTrue(log.contains("skipped locked"))
    }

    func testSupportingLogDoesNotReplaceCycleStatus() throws {
        let audit = SyncAudit(
            appSupport: tempDir,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        audit.record(category: "synced", detail: "upToDate")
        audit.append(category: "convergence", detail: "category:1:0")

        let statusData = try Data(contentsOf: URL(fileURLWithPath: tempDir + "/daemon-status.json"))
        let status = try JSONDecoder().decode(DaemonStatus.self, from: statusData)
        XCTAssertEqual(status.result, "synced")
        XCTAssertEqual(status.detail, "upToDate")
        let log = try String(contentsOfFile: tempDir + "/daemon.log", encoding: .utf8)
        XCTAssertTrue(log.contains("convergence category:1:0"))
    }

    func testFreeFormRecordAndAppendKeepOneLinePerEntry() throws {
        let audit = SyncAudit(appSupport: tempDir, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        audit.record(category: "failed", detail: "first\nsecond\r\nthird\u{2028}last\n")
        audit.append(category: "convergence", detail: "source\rerror\u{2029}detail")
        let statusData = try Data(contentsOf: URL(fileURLWithPath: tempDir + "/daemon-status.json"))
        let status = try JSONDecoder().decode(DaemonStatus.self, from: statusData)
        XCTAssertEqual(status.detail, "first second third last")
        let log = try String(contentsOfFile: tempDir + "/daemon.log", encoding: .utf8)
        XCTAssertEqual(log, "\(status.timestamp) failed first second third last\n"
                       + "\(status.timestamp) convergence source error detail\n")
        XCTAssertEqual(log.components(separatedBy: .newlines).filter { !$0.isEmpty }.count, 2)
    }

    func testControlCharactersAreRemovedFromAuditAndCLI() throws {
        let raw = "before \u{1B}[31mred\u{1B}[0m\u{0}after\u{7}\u{7F}\u{9B}tail"
        let audit = SyncAudit(appSupport: tempDir)
        audit.record(category: "failed", detail: raw)
        audit.append(category: "convergence", detail: raw)
        let data = try Data(contentsOf: URL(fileURLWithPath: tempDir + "/daemon-status.json"))
        let status = try JSONDecoder().decode(DaemonStatus.self, from: data)
        let log = try String(contentsOfFile: tempDir + "/daemon.log", encoding: .utf8)
        let run = DaemonCLI.execute(["run"], appSupport: tempDir, readFile: { _ in data },
                                   runCycle: { .failed(.preflight(raw)) }, now: Date.init)
        let display = DaemonCLI.renderStatus(data: data, path: tempDir, json: false, now: Date())
        for value in [status.detail, log, run.stdout, display.output] {
            XCTAssertFalse(value.unicodeScalars.contains { $0.properties.generalCategory == .control && $0.value != 10 })
            XCTAssertFalse(value.contains("[31m"))
            XCTAssertFalse(value.contains("[0m"))
            XCTAssertTrue(value.contains("before red"))
        }
    }

    func testConcurrentRecordsPreserveEveryLogLine() throws {
        let fileService = CoordinatedAuditFileService(logPath: tempDir + "/daemon.log")
        let audit = SyncAudit(appSupport: tempDir, fileService: fileService)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "SyncAuditTests.concurrent", attributes: .concurrent)

        for detail in ["first", "second"] {
            group.enter()
            queue.async {
                audit.record(category: "synced", detail: detail)
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + TestWait.hostedActionTimeoutSeconds), .success)
        let log = try String(contentsOfFile: tempDir + "/daemon.log", encoding: .utf8)
        XCTAssertEqual(log.split(separator: "\n").count, 2)
        XCTAssertTrue(log.contains("synced first"))
        XCTAssertTrue(log.contains("synced second"))
    }
}

private final class CoordinatedAuditFileService: FileServiceProtocol {
    private let base = FileService()
    private let logPath: String
    private let condition = NSCondition()
    private var logReadCount = 0

    init(logPath: String) {
        self.logPath = logPath
    }

    func readFile(at path: String) throws -> String {
        if path == logPath {
            condition.lock()
            logReadCount += 1
            if logReadCount == 1 {
                _ = condition.wait(until: Date().addingTimeInterval(0.2))
            } else {
                condition.broadcast()
            }
            condition.unlock()
        }
        return try base.readFile(at: path)
    }

    func writeFile(at path: String, content: String) throws { try base.writeFile(at: path, content: content) }
    func deleteFile(at path: String) throws { try base.deleteFile(at: path) }
    func fileExists(at path: String) -> Bool { base.fileExists(at: path) }
    func isExecutableFile(at path: String) -> Bool { base.isExecutableFile(at: path) }
    func directoryExists(at path: String) -> Bool { base.directoryExists(at: path) }
    func createDirectory(at path: String) throws { try base.createDirectory(at: path) }
    func deleteDirectory(at path: String) throws { try base.deleteDirectory(at: path) }
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {
        try base.createSymlink(at: linkPath, pointingTo: targetPath)
    }
    func symlinkTarget(at path: String) throws -> String { try base.symlinkTarget(at: path) }
    func isSymlink(at path: String) -> Bool { base.isSymlink(at: path) }
    func listDirectory(at path: String) throws -> [String] { try base.listDirectory(at: path) }
    func contentsHash(at path: String) throws -> String { try base.contentsHash(at: path) }
}

private struct AuditHealthyEngine: SyncEngineProtocol {
    func sync(root: String, message: String, credential: GitCredential?, context: ModelContext,
              prepare: ((ModelContext) throws -> Void)?) throws -> SyncOutcome {
        try prepare?(context)
        return .synced(pushed: false, warnings: [])
    }

    func inspectConflicts(root: String, credential: GitCredential?, context: ModelContext) throws -> ConflictInspection {
        fatalError("unused")
    }

    func resolveConflicts(root: String, picks: [String: ResolutionPick], credential: GitCredential?,
                          context: ModelContext) throws -> SyncOutcome {
        fatalError("unused")
    }
}

private struct AuditEmptyCredentialStore: CredentialStoreProtocol {
    func store(token: String, username: String, forHost host: String) throws {}
    func credential(forHost host: String) -> GitCredential? { nil }
    func delete(forHost host: String) throws {}
}
