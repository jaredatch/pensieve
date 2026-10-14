import AppKit
import Darwin
import XCTest
@testable import Pensieve

@MainActor
final class AppSocketCommandLifetimeTests: XCTestCase {
    func testQuitWaitsThroughTheReplyAndRefusesNewCommands() async throws {
        let directory = try SocketTestDirectory()
        let paths = AppRuntimePaths(storeRoot: directory.path + "/store", appSupportDir: directory.path)
        let runtime = try await makeRuntime(paths: paths)
        defer { runtime.commandServer?.stop() }
        let model = runtime.syncModel
        model.applyConfiguration(.success(.init(remoteURL: "https://fixture.test/store.git", hasLocalBranches: true)),
            order: model.beginConfiguration())
        let release = TestWait.Gate(owner: self)
        defer { release.open() }
        var entered = false
        model.installSyncRequest {
            entered = true
            await BlockingWork.run { try? release.wait() }
            try? directory.files.writeFile(at: directory.path + "/applied", content: "finished")
            model.apply(.synced(pushed: true, warnings: [], completedAt: Date()))
        }
        let steps = paths.syncSteps
        let path = CLIProtocol.socketPath(appSupport: directory.path, bundleID: try XCTUnwrap(Bundle.main.bundleIdentifier))
        var reply: CLIReply?
        let command = Task { reply = try? await sendCommand(path) }
        await TestWait.until(failureMessage: "Command did not start") { entered }
        XCTAssertEqual(steps.pendingCount, 1)
        var questions = 0
        let termination = PendingSaveTermination(delay: 0.05) { _, _ in
            questions += 1
            return .init(update: { _ in true }, dismiss: {})
        }
        var quitReplies: [Bool] = []
        let answer = PensieveAppDelegate.terminationReply(hasUnsavedChanges: false, questionOpen: false,
            confirm: { _ in XCTFail("No draft") }, reply: { quitReplies.append($0) },
            saveTermination: termination, steps: steps, runtime: runtime)
        XCTAssertEqual(answer, .terminateLater)
        await TestWait.until(failureMessage: "Quit did not ask about pending work") { questions == 1 }
        XCTAssertTrue(quitReplies.isEmpty)
        let refused = try await refusedRequest(path)
        XCTAssertEqual(refused.exitCode, 3)
        XCTAssertEqual(refused.envelope.error?.code, "app_quitting")
        XCTAssertEqual(refused.envelope.error?.retryable, true)
        release.open()
        await TestWait.forTask(command, failureMessage: "Command reply was lost during quit")
        XCTAssertTrue(reply?.envelope.ok == true)
        guard case let .object(result) = reply?.envelope.data else { return XCTFail("Missing cycle reply") }
        XCTAssertEqual(result["pushed"], .bool(true))
        XCTAssertEqual(try directory.files.readFile(at: directory.path + "/applied"), "finished")
        await TestWait.until(failureMessage: "Quit did not complete") { quitReplies == [true] }
        XCTAssertEqual(steps.pendingCount, 0)
    }

    private func makeRuntime(paths: AppRuntimePaths) async throws -> AppRuntime {
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
            launchReconcile: { _, _ in
                LaunchReconcileOutcome(rebuild: RebuildResult(), migrationRan: false, ingestedHeadStamp: "fixture")
            }, launchBackfill: { _ in }, hasRemoteConfigured: { false }, paths: paths,
            gitUsabilityProbe: { .usable })
        runtime.start()
        await TestWait.until(failureMessage: "Runtime did not become ready") { runtime.commandsReady }
        return runtime
    }

    private func sendCommand(_ path: String) async throws -> CLIReply {
        try await BlockingWork.run {
            let client = try SocketTransport.connect(to: path)
            defer { close(client) }
            _ = try SocketTransport.readFrame(client, limit: 1_024, timeout: TestWait.hostedActionTimeoutSeconds)
            try SocketTransport.writeFrame(CLIRequest(command: "sync", acknowledgeReadiness: true, requiresCommit: true),
                to: client, timeout: TestWait.hostedActionTimeoutSeconds)
            _ = try SocketTransport.readFrame(client, limit: 1_024, timeout: TestWait.hostedActionTimeoutSeconds)
            try SocketTransport.writeFrame(CLICommandCommit(commit: true), to: client,
                timeout: TestWait.hostedActionTimeoutSeconds)
            return try JSONDecoder().decode(CLIReply.self, from: SocketTransport.readFrame(client,
                limit: 4_096, timeout: TestWait.hostedActionTimeoutSeconds))
        }
    }

    private func refusedRequest(_ path: String) async throws -> CLIReply {
        try await BlockingWork.run {
            let client = try SocketTransport.connect(to: path)
            defer { close(client) }
            _ = try SocketTransport.readFrame(client, limit: 1_024, timeout: TestWait.hostedActionTimeoutSeconds)
            try SocketTransport.writeFrame(CLIRequest(command: "skill list"), to: client,
                timeout: TestWait.hostedActionTimeoutSeconds)
            return try JSONDecoder().decode(CLIReply.self, from: SocketTransport.readFrame(client,
                limit: 4_096, timeout: TestWait.hostedActionTimeoutSeconds))
        }
    }
}
