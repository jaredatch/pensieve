import SwiftData
import XCTest
@testable import Pensieve

/// A real coordinator, file audit and local git repository. Only the cycle's engine failure is injected;
/// the credential lookup and the built command's disk reads run through production implementations.
@MainActor
final class SyncFailureAuditFixture {
    let disk: GitFailureFixture
    let coordinator: SyncCoordinator
    let engine = AuditFailureEngine()
    let audit: SyncAudit
    let credentials = InMemoryCredentialStore()

    init(token: String? = nil, usability: GitUsability? = nil) async throws {
        disk = try GitFailureFixture()
        try disk.seedRepository()
        if let token { try credentials.store(token: token, username: "kept", forHost: "fixture.test") }
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        coordinator = SyncCoordinator(modelContainer: container)
        audit = SyncAudit(appSupport: disk.support)
        let git = try usability.map { try disk.broken($0) } ?? disk.paths.makeGitService()
        await coordinator.configure(engine: engine, git: git, credentials: credentials, root: disk.root, audit: audit,
            machine: (InertMachineIdentity(), InertMachineStateService()))
    }

    func run(_ error: Error) async -> SyncCycleResult {
        engine.failure = error
        return await coordinator.runCycle()
    }

    func status() throws -> DaemonStatus {
        try JSONDecoder().decode(DaemonStatus.self,
            from: disk.files.readData(at: disk.support + "/daemon-status.json"))
    }

    func log(_ suffix: String = "") throws -> String { try disk.files.readFile(at: disk.support + "/daemon.log" + suffix) }

    func rotate() {
        for _ in 0..<70 { audit.append(category: "fixture", detail: String(repeating: "x", count: 4096)) }
    }

    func assertNoSecrets(_ secrets: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        for name in ["daemon-status.json", "daemon.log", "daemon.log.1"] {
            let path = disk.support + "/" + name
            guard disk.files.fileExists(at: path) else { continue }
            let text = try disk.files.readFile(at: path)
            for secret in secrets { XCTAssertFalse(text.contains(secret), "Secret in \(name)", file: file, line: line) }
        }
    }

    func command(_ arguments: [String]) async throws -> (Int32?, String) {
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/pensieve")
        process.arguments = arguments + ["--app-support", disk.support]
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = disk.base
        environment["HOME"] = disk.base
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let result = try await BlockingWork.run {
            try CLIProcessProbe.run(process, timeout: TestWait.hostedActionTimeoutSeconds)
        }
        XCTAssertFalse(result.timedOut)
        let bytes = try output.fileHandleForReading.readToEnd() ?? Data()
        return (result.status, try XCTUnwrap(String(data: bytes, encoding: .utf8)))
    }

    func assertCommandReads(_ status: DaemonStatus) async throws {
        let (exit, output) = try await command(["status", "--json"])
        XCTAssertEqual(exit, 1)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual((envelope["error"] as? [String: Any])?["code"] as? String, "sync_failed")
        XCTAssertEqual((envelope["data"] as? [String: Any])?["detail"] as? String, status.detail)
        let (logExit, logOutput) = try await command(["log", "--lines", "1"])
        XCTAssertEqual(logExit, 0)
        XCTAssertTrue(logOutput.hasSuffix("\(status.timestamp) failed \(status.detail)\n"))
    }
}

final class AuditFailureEngine: SyncEngineProtocol {
    var failure: Error = SyncError.ingestIncomplete
    func sync(root: String, message: String, credential: GitCredential?, context: ModelContext,
              prepare: ((ModelContext) throws -> Void)?) throws -> SyncOutcome { throw failure }
    func inspectConflicts(root: String, credential: GitCredential?, context: ModelContext) throws -> ConflictInspection {
        throw failure
    }
    func resolveConflicts(root: String, picks: [String: ResolutionPick], credential: GitCredential?,
                          context: ModelContext) throws -> SyncOutcome { throw failure }
}

enum UnlocalizedAuditFailure: Error { case broken(String) }
struct LiteralAuditFailure: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}
