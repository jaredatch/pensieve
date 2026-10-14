import Darwin
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class AppRuntimeCommandReadinessTests: XCTestCase {
    func testSocketWaitsForIngestionAndSetupInEitherCompletionOrder() async throws {
        for first in ["ingest", "setup"] { try await assertReadiness(first: first) }
    }

    private func assertReadiness(first: String) async throws {
        let directory = try SocketTestDirectory()
        let paths = AppRuntimePaths(storeRoot: directory.path + "/store", appSupportDir: directory.path)
        let ingest = TestWait.Gate(owner: self), setup = TestWait.Gate(owner: self)
        defer { ingest.open(); setup.open() }
        let ingestEntered = expectation(description: "ingest entered")
        let setupEntered = expectation(description: "setup entered")
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
            launchReconcile: { context, _ in
                ingestEntered.fulfill()
                try? ingest.wait()
                context.insert(Skill(name: "Ingested", directoryName: "ingested"))
                try? context.save()
                return LaunchReconcileOutcome(rebuild: RebuildResult(), migrationRan: false, ingestedHeadStamp: "stamp")
            }, launchBackfill: { _ in }, hasRemoteConfigured: { false }, paths: paths,
            gitUsabilityProbe: { .usable }, coordinatorConfigure: { _ in
                await BlockingWork.run { setupEntered.fulfill(); try? setup.wait() }
            })
        defer { runtime.commandServer?.stop() }
        runtime.start()
        await fulfillment(of: [ingestEntered, setupEntered], timeout: TestWait.timeoutSeconds)
        let received = Counter()
        let sent = expectation(description: "request sent while launch held")
        let bundleID = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let socket = CLIProtocol.socketPath(appSupport: directory.path, bundleID: bundleID)
        let request = sendList(socket: socket, sent: sent, received: received)
        await fulfillment(of: [sent], timeout: TestWait.timeoutSeconds)
        let refusal = await runtime.waitForCommandReadiness(timeout: 0.03) // upper-bound: held launch expires.
        XCTAssertEqual(refusal?.exitCode, 3)
        XCTAssertEqual(refusal?.envelope.error?.code, "app_starting")
        XCTAssertEqual(refusal?.envelope.error?.message, runtime.library.addFenceReason)
        XCTAssertEqual(refusal?.envelope.error?.retryable, true)
        if first == "ingest" {
            ingest.open()
            await TestWait.until(failureMessage: "ingestion did not finish") { runtime.launchWorkCompleted }
        } else {
            setup.open()
            await runtime.bootstrapTask.value
        }
        let stillStarting = await runtime.waitForCommandReadiness(timeout: 0.03) // upper-bound: held launch expires.
        XCTAssertNotNil(stillStarting)
        XCTAssertEqual(received.value, 0, "one finished phase must not expose stale rows")
        ingest.open(); setup.open()
        let reply = try await request.value
        XCTAssertEqual(reply.exitCode, 0)
        XCTAssertEqual(reply.envelope.data, .array([.object([
            "slug": .string("ingested"), "name": .string("Ingested"),
            "description": .string(""), "tags": .array([])])]))
        XCTAssertTrue(runtime.commandsReady)
    }

    func testLockDeferralKeepsCommandsStartingUntilTheRuntimeRetryFinishes() async throws {
        let directory = try SocketTestDirectory()
        let paths = AppRuntimePaths(storeRoot: directory.path + "/store", appSupportDir: directory.path)
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: paths.syncLockPath))
        defer { held.release() }
        let calls = Counter()
        let runtime = try AppRuntime(scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
            launchReconcile: { _, _ in
                calls.increment()
                return LaunchReconcileOutcome(rebuild: RebuildResult(), migrationRan: false, ingestedHeadStamp: "stamp")
            }, launchBackfill: { _ in }, hasRemoteConfigured: { false }, launchIngestRetryNanoseconds: 10_000_000,
            paths: paths, gitUsabilityProbe: { .usable })
        defer { runtime.commandServer?.stop() }
        runtime.start()
        await runtime.bootstrapTask.value
        let refusal = await runtime.waitForCommandReadiness(timeout: 0.05) // upper-bound: a held lock must time out promptly.
        XCTAssertEqual(refusal?.envelope.error?.code, "app_starting")
        XCTAssertEqual(calls.value, 0)
        held.release()
        let ready = await runtime.waitForCommandReadiness()
        XCTAssertNil(ready)
        XCTAssertEqual(calls.value, 1)
    }

    private func sendList(socket: String, sent: XCTestExpectation, received: Counter) -> Task<CLIReply, Error> {
        BlockingWork.task {
            let client = try SocketTransport.connect(to: socket)
            defer { close(client) }
            _ = try SocketTransport.readFrame(client, limit: 1_024, timeout: TestWait.timeoutSeconds)
            try SocketTransport.writeFrame(CLIRequest(command: "skill list"), to: client, timeout: TestWait.timeoutSeconds)
            sent.fulfill()
            let data = try SocketTransport.readFrame(client, limit: CLIProtocol.replyLimit, timeout: TestWait.timeoutSeconds)
            received.increment()
            return try JSONDecoder().decode(CLIReply.self, from: data)
        }
    }
}
