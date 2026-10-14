import XCTest
@testable import Pensieve

@MainActor
final class CLISyncHandlerTests: XCTestCase {
    func testSyncReturnsTheRequestedCycleAndPreservesAppMessages() async throws {
        let cases: [(SyncCycleResult, (Int32, String?))] = [
            (.synced(pushed: true, warnings: ["warning"], completedAt: Date(), pulled: false), (0, nil)),
            (.synced(pushed: false, warnings: [], completedAt: Date(), pulled: true), (0, nil)),
            (.conflicted(["skills/review/SKILL.md"]), (5, "conflict")),
            (.noRemote, (1, "not_connected")), (.locked, (1, "sync_running")),
            (.failed("Sign in to Pensieve's HTTPS sync remote."), (1, "sync_failed")),
            (.failed(SyncError.ingestIncomplete.localizedDescription), (1, "sync_failed")),
            (.storeUnreadable("Newer schema"), (1, "store_unreadable")), (.branchless, (1, "sync_failed"))
        ]
        for (cycle, expected) in cases {
            let (exit, code) = expected
            let model = SyncModel(git: TestPaths.git, root: "/unused-sync-result")
            var runs = 0
            model.installSyncRequest { runs += 1; model.apply(cycle) }
            let result = await CLISyncHandler(model: model).handle()
            XCTAssertEqual(runs, 1)
            XCTAssertEqual(result.exitCode, exit)
            XCTAssertEqual(result.envelope.error?.code, code)
            if case let .failed(message) = cycle { XCTAssertEqual(result.envelope.error?.message, message) }
            if case let .synced(pushed, _, _, _, pulled) = cycle {
                guard case let .object(fields) = result.envelope.data else { return XCTFail("Missing sync result") }
                XCTAssertEqual(fields["pushed"], .bool(pushed))
                XCTAssertEqual(fields["pulled"], .bool(pulled))
            }
        }
    }

    func testCommandWaitsForFollowupAndReturnsConflictWhenFollowupIsDropped() async throws {
        for conflict in [false, true] {
            let model = SyncModel(git: TestPaths.git, root: "/unused-sync-followup")
            let release = TestWait.Gate(owner: self)
            defer { release.open() }
            var entered = false
            var starts = 0
            model.installSyncRequest {
                starts += 1
                if starts == 1 {
                    entered = true
                    await BlockingWork.run { try? release.wait() }
                    model.apply(conflict ? .conflicted(["skills/review/SKILL.md"])
                        : .synced(pushed: true, warnings: [], completedAt: Date()))
                } else {
                    model.apply(.synced(pushed: false, warnings: ["follow-up"], completedAt: Date(), pulled: true))
                }
            }
            model.installPendingSyncRequest { request in Task { await model.syncAndReport(request) } }
            let previous = Task { await model.syncNowAndReport() }
            await TestWait.until(failureMessage: "First cycle did not start") { entered }
            var reply: CLIReply?
            var submitted = false
            let command = Task {
                submitted = true
                reply = await CLISyncHandler(model: model).handle()
            }
            await TestWait.until(failureMessage: "Command did not enqueue") { submitted }
            XCTAssertNil(reply)
            XCTAssertEqual(starts, 1)
            release.open()
            await previous.value
            await TestWait.forTask(command, failureMessage: "Queued command never finished")
            let result = try XCTUnwrap(reply)
            XCTAssertEqual(starts, conflict ? 1 : 2)
            XCTAssertEqual(result.exitCode, conflict ? 5 : 0)
            if conflict { XCTAssertEqual(result.envelope.error?.code, "conflict") } else {
                guard case let .object(fields) = result.envelope.data else { return XCTFail("Missing follow-up result") }
                XCTAssertEqual(fields["pushed"], .bool(false))
                XCTAssertEqual(fields["pulled"], .bool(true))
                XCTAssertEqual(fields["warnings"], .array([.string("follow-up")]))
            }
        }
    }

    func testConflictAndKnownAbsenceRefuseWithoutStartingACycle() async {
        for state in [SyncModel.SyncState.conflicted(["skills/review/SKILL.md"]), .unconfigured] {
            let model = SyncModel(git: TestPaths.git, root: "/unused-sync-refusal", initialState: state)
            var starts = 0
            model.installSyncRequest { starts += 1 }
            let reply = await CLISyncHandler(model: model).handle()
            XCTAssertEqual(starts, 0)
            XCTAssertEqual(reply.exitCode, state == .unconfigured ? 1 : 5)
            XCTAssertEqual(reply.envelope.error?.code, state == .unconfigured ? "not_connected" : "conflict")
        }
    }
}
