import AppKit
import XCTest
@testable import Pensieve

extension PendingSaveTerminationTests {
    func testQuitStopsWaitingWhenSavePausesForRepairAndStillWaitsForSync() async throws {
        for syncing in [false, true] {
            let h = try ManifestSaveFixture()
            defer { h.cleanup() }
            let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
            defer { lock.release() }
            h.categories.rename(h.local, to: "Waiting", context: h.context)
            let steps = SyncStepModel()
            let step = syncing ? steps.begin() : nil
            var questions: [PendingSaveTermination.Question] = []
            var choose: ((Bool) -> Void)?
            let quit = PendingSaveTermination(delay: 0) { question, resolve in
                choose = resolve
                questions.append(question)
                return .init(update: { questions.append($0); return true }, dismiss: {})
            }
            var replies: [Bool] = []
            let reply = PensieveAppDelegate.terminationReply(hasUnsavedChanges: false, questionOpen: false,
                confirm: { _ in XCTFail("No editor draft") }, reply: { replies.append($0) },
                saves: h.saves, saveTermination: quit, steps: steps)
            XCTAssertEqual(reply, .terminateLater)
            await TestWait.until(failureMessage: "Active save must ask today's quit question") { !questions.isEmpty }
            XCTAssertEqual(questions.last, syncing ? .savingAndSyncing : .saving)
            if !syncing { try XCTUnwrap(choose)(false) } // Wait must finish when the save pauses.
            try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "damaged")
            lock.release()
            await h.saves.waitUntilIdle()
            if let step {
                await TestWait.until(failureMessage: "Paused edits must leave only the sync question") {
                    questions.last == .syncing
                }
                steps.finish(step)
            }
            await TestWait.until(failureMessage: "Quit must finish when only paused edits remain") { replies == [true] }
            XCTAssertEqual(h.saves.pendingCount, 1, "Quit did not discard the waiting edit")
            let freshQuit = PendingSaveTermination(delay: 0)
            XCTAssertEqual(PensieveAppDelegate.terminationReply(hasUnsavedChanges: false, questionOpen: false,
                confirm: { _ in XCTFail("No draft") }, reply: { _ in XCTFail("Immediate quit needs no reply") },
                saves: h.saves, saveTermination: freshQuit), .terminateNow)
            // Release the waiting observer even on the regression's failing path.
            h.saves.requestRepair()
            await h.saves.replaceWithThisMac(context: h.context)
            await h.saves.waitUntilIdle()
        }
    }
}
