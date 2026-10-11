import AppKit
import XCTest
@testable import Pensieve

extension PendingSaveTerminationTests {
    func testShownQuitQuestionTracksPendingSaveAndSyncStep() async throws {
        for startsWithStep in [true, false] {
            let h = try ManifestSaveFixture()
            let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
            defer { lock.release(); h.cleanup() }
            h.categories.rename(h.local, to: "Waiting", context: h.context)
            let steps = SyncStepModel(), quit = PendingSaveTermination(delay: 0)
            var step = startsWithStep ? steps.begin() : nil
            defer { if let step { steps.finish(step) } }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.orderFront(nil)
            defer { window.close() }
            var answers: [Bool] = []
            quit.wait(for: h.saves, steps: steps) { answers.append($0) }
            await TestWait.until(failureMessage: "Quit question did not appear") {
                NSApp.windows.contains { $0.attachedSheet != nil }
            }
            let parent = try XCTUnwrap(NSApp.windows.first { $0.attachedSheet != nil })
            let sheet = try XCTUnwrap(parent.attachedSheet)
            sheet.animationBehavior = .none
            let shows = { (question: PendingSaveTermination.Question) in Self.shows(question, in: sheet) }
            let saveOnly = PendingSaveTermination.Question.saving
            let both = PendingSaveTermination.Question.savingAndSyncing
            await TestWait.until(failureMessage: "Initial quit text did not render") {
                shows(startsWithStep ? both : saveOnly)
            }
            if let active = step { steps.finish(active); step = nil } else { step = steps.begin() }
            await TestWait.until(failureMessage: "Shown quit text did not follow sync work, startsWithStep=\(startsWithStep)") {
                shows(startsWithStep ? saveOnly : both)
            }
            guard shows(startsWithStep ? saveOnly : both) else {
                lock.release()
                await h.saves.waitUntilIdle()
                if let active = step { steps.finish(active); step = nil }
                await TestWait.until(failureMessage: "Failed question did not detach during cleanup") {
                    parent.attachedSheet == nil
                }
                return
            }
            XCTAssertFalse(shows(startsWithStep ? both : saveOnly))
            // Return to both pending, then let just the save finish.
            if step == nil { step = steps.begin() }
            await TestWait.until(failureMessage: "Combined question did not return") { shows(both) }
            try await assertSaveChanges(h, lock: lock, shows: shows)
            if let active = step { steps.finish(active); step = nil }
            await TestWait.until(failureMessage: "Idle work did not finish quit and detach its sheet") {
                answers == [true] && parent.attachedSheet == nil
            }
        }
    }

    private static func shows(_ question: PendingSaveTermination.Question, in sheet: NSWindow) -> Bool {
        sheet.contentView?.layoutSubtreeIfNeeded()
        let strings = sheet.contentView.map { views($0).compactMap { ($0 as? NSTextField)?.stringValue } } ?? []
        switch question {
        case .saving:
            return strings.contains("Pensieve is still saving a change.") && strings.contains(
                "It's waiting for sync to finish. If you quit now, the change won't be saved.")
        case .syncing:
            return strings.contains("Pensieve is still finishing a sync step.") && strings.contains(
                "If you quit now, it stops partway.")
        case .savingAndSyncing:
            return strings.contains("Pensieve is still finishing a sync step and saving a change.") && strings.contains(
                "If you quit now, the sync step stops partway and the change won't be saved.")
        }
    }

    private func assertSaveChanges(_ h: ManifestSaveFixture, lock: SyncLock,
                                   shows: @escaping (PendingSaveTermination.Question) -> Bool) async throws {
        lock.release()
        await h.saves.waitUntilIdle()
        await TestWait.until(failureMessage: "Completed save remained in quit text") { shows(.syncing) }
        XCTAssertFalse(shows(.savingAndSyncing))
        let nextLock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { nextLock.release() }
        h.categories.rename(h.local, to: "Again", context: h.context)
        await TestWait.until(failureMessage: "New save did not enter quit text") { shows(.savingAndSyncing) }
        nextLock.release()
        await h.saves.waitUntilIdle()
    }

    func testClosedQuitQuestionCannotAcknowledgeAnUnseenWarning() async throws {
        for workGrows in [false, true] {
            let h = try ManifestSaveFixture()
            defer { h.cleanup() }
            let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
            defer { lock.release() }
            h.categories.rename(h.local, to: "Waiting", context: h.context)
            let steps = SyncStepModel()
            var step = workGrows ? nil : steps.begin()
            defer { if let step { steps.finish(step) } }
            var questions: [PendingSaveTermination.Question] = []
            var callbacks: [(Bool) -> Void] = []
            var refusedUpdates = 0
            let quit = PendingSaveTermination(delay: 0) { question, resolve in
                questions.append(question)
                callbacks.append(resolve)
                // NSAlert has detached after the button press, before delivering its response.
                return .init(update: { _ in refusedUpdates += 1; return false }, dismiss: {})
            }
            var answers: [Bool] = []
            quit.wait(for: h.saves, steps: steps) { answers.append($0) }
            await TestWait.until(failureMessage: "Quit question did not appear") { callbacks.count == 1 }
            if let active = step { steps.finish(active); step = nil } else { step = steps.begin() }
            await TestWait.until(failureMessage: "Pending work did not attempt the late native update") { refusedUpdates > 0 }
            callbacks[0](true)
            if workGrows {
                XCTAssertTrue(answers.isEmpty, "A closed sheet cannot warn about work that started afterward")
                XCTAssertEqual(questions, [.saving, .savingAndSyncing])
                XCTAssertEqual(callbacks.count, 2)
                try XCTUnwrap(callbacks.last)(true)
            } else {
                XCTAssertEqual(questions, [.savingAndSyncing], "Consent still covers the remaining save")
                XCTAssertEqual(callbacks.count, 1, "Finishing sync must not re-ask Quit Anyway")
            }
            XCTAssertEqual(answers, [true])
            lock.release()
            await h.saves.waitUntilIdle()
        }
    }

    func testInjectedQuitPresenterTracksCombinedWorkAndChecksCurrentConsent() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { lock.release() }
        h.categories.rename(h.local, to: "Waiting", context: h.context)
        let steps = SyncStepModel()
        var questions: [PendingSaveTermination.Question] = []
        var callbacks: [(Bool) -> Void] = []
        var dismissals = 0
        let quit = PendingSaveTermination(delay: 0) { question, resolve in
            questions.append(question)
            callbacks.append(resolve)
            return .init(update: { questions.append($0); return true }, dismiss: { dismissals += 1 })
        }
        var answers: [Bool] = []
        quit.wait(for: h.saves, steps: steps) { answers.append($0) }
        await TestWait.until(failureMessage: "Injected save question did not appear") { callbacks.count == 1 }
        XCTAssertEqual(questions, [.saving])
        let step = steps.begin()
        // This callback deliberately precedes the queued Observation update.
        try XCTUnwrap(callbacks.first)(true)
        XCTAssertTrue(answers.isEmpty, "Quit Anyway cannot consent to a sync step the old question did not name")
        XCTAssertEqual(questions.last, .savingAndSyncing)
        XCTAssertEqual(callbacks.count, 2, "An answer to stale copy must reoffer the question")
        try XCTUnwrap(callbacks.dropFirst().first)(false)
        XCTAssertEqual(dismissals, 2)
        quit.requestQuestion()
        XCTAssertEqual(callbacks.count, 3, "The combined question must use the same injected presenter")
        XCTAssertEqual(questions.last, .savingAndSyncing)
        callbacks[0](true)
        XCTAssertTrue(answers.isEmpty, "A dismissed question cannot answer the reopened question")
        steps.finish(step)
        await TestWait.until(failureMessage: "Injected question did not drop the completed sync step") {
            questions.last == .saving
        }
        try XCTUnwrap(callbacks.dropFirst(2).first)(true)
        XCTAssertEqual(answers, [true])
        XCTAssertEqual(dismissals, 3)
        lock.release()
        await h.saves.waitUntilIdle()
        XCTAssertEqual(answers, [true], "Completion cannot answer Quit Anyway twice")
    }
}
