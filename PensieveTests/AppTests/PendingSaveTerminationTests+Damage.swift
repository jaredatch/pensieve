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
            do {
                await TestWait.until(failureMessage: "Paused edits need their own Quit or Cancel question") {
                    questions.last?.message == "A change is waiting for the library file to be repaired."
                }
                XCTAssertEqual(questions.last?.detail, "It's kept on this Mac and saves when you repair the file here. "
                    + "If another Mac repairs the file first, its version replaces your change.")
                try XCTUnwrap(choose)(true)
            }
            await TestWait.until(failureMessage: "Answered quit must finish") { replies == [true] }
            XCTAssertEqual(h.saves.pendingCount, 1, "Quit did not discard the waiting edit")
            try await assertPausedQuitCanCancel(h)
            // Release the waiting observer even on the regression's failing path.
            h.saves.requestRepair()
            await h.saves.replaceWithThisMac(context: h.context)
            await h.saves.waitUntilIdle()
        }
    }

    private func assertPausedQuitCanCancel(_ h: ManifestSaveFixture) async throws {
    var cancel: ((Bool) -> Void)?
    var cancelled: [Bool] = []
    let freshQuit = PendingSaveTermination(delay: 0) { _, answer in
        cancel = answer
        return .init(update: { _ in true }, dismiss: {})
    }
    XCTAssertEqual(PensieveAppDelegate.terminationReply(hasUnsavedChanges: false, questionOpen: false,
        confirm: { _ in XCTFail("No draft") }, reply: { cancelled.append($0) },
        saves: h.saves, saveTermination: freshQuit), .terminateLater)
    await TestWait.until(failureMessage: "Paused Quit must offer Cancel") { cancel != nil }
    try XCTUnwrap(cancel)(false)
    XCTAssertEqual(cancelled, [false], "Cancel ends this quit request without waiting for repair")
    }
}
