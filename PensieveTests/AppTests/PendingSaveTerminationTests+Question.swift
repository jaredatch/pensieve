import AppKit
import XCTest
@testable import Pensieve

extension PendingSaveTerminationTests {
    func fixtureAfterCategoryRefusal() async throws -> ManifestSaveFixture {
        let h = try ManifestSaveFixture(waitSeconds: 5)
        h.recording.failingWrites = 1
        h.categories.rename(h.local, to: "Refused", context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.local.name, "Local")
        return h
    }

    func pressDefault(in sheet: NSWindow) throws {
        let button = try XCTUnwrap(sheet.defaultButtonCell?.controlView as? NSButton)
        XCTAssertEqual(button.title, "Quit")
        button.performClick(nil)
    }

    func assertQuestionText(_ question: PendingSaveTermination.Question, in rendered: [NSView]) {
        let expected: [String]
        switch question {
        case .saving:
            expected = ["Pensieve is still saving a change.",
                "It's waiting for sync to finish. If you quit now, the change won't be saved."]
        case .syncing:
            expected = ["Pensieve is still finishing a sync step.", "If you quit now, it stops partway."]
        case .savingAndSyncing:
            expected = ["Pensieve is still finishing a sync step and saving a change.",
                "If you quit now, the sync step stops partway and the change won't be saved."]
        case .waitingForRepair:
            expected = ["A change is waiting for the library file to be repaired.",
                "It's kept on this Mac and saves when you repair the file here. "
                    + "If another Mac repairs the file first, its version replaces your change."]
        }
        let strings = rendered.compactMap { ($0 as? NSTextField)?.stringValue }
        for text in expected { XCTAssertTrue(strings.contains(text), "Missing native alert text: \(text)") }
    }

    func assertQuitKeyboardBindings(_ question: PendingSaveTermination.Question, in sheet: NSWindow) throws {
        let buttons = Self.views(try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSButton }
        let firstTitle = question == .waitingForRepair ? "Quit" : "Wait"
        let secondTitle = question == .waitingForRepair ? "Cancel" : "Quit Anyway"
        let first = try XCTUnwrap(buttons.first { $0.title == firstTitle })
        let second = try XCTUnwrap(buttons.first { $0.title == secondTitle })
        XCTAssertEqual(sheet.defaultButtonCell?.title, firstTitle, "Return must choose the current default")
        XCTAssertEqual(first.keyEquivalent, "\r", "The default button keeps Return")
        XCTAssertEqual(second.keyEquivalent, "", "The local monitor is the single Escape binding")
        XCTAssertTrue(first.keyEquivalentModifierMask.isEmpty)
        XCTAssertTrue(second.keyEquivalentModifierMask.isEmpty)
    }

    func testCancelMonitorIsRemovedOnlyAfterItsHandlerReturns() async throws {
        let host = makeQuestionWindow()
        let restoreWindows = isolateQuestionHost(host)
        host.makeKeyAndOrderFront(nil)
        defer { host.close(); host.contentView = nil; restoreWindows() }
        let monitor = try QuitMonitorRemovalProbe()
        defer { monitor.stop() }
        var answers: [Bool] = []
        let presentation = PendingSaveTermination.present(.saving) { answers.append($0) }
        defer { presentation.dismiss() }
        let sheet = try XCTUnwrap(host.attachedSheet)
        sheet.animationBehavior = .none
        try sendQuitKey("Escape", to: sheet)
        XCTAssertTrue(monitor.sawKeyHandler)
        XCTAssertEqual(monitor.reentrantRemovals, 0, "A local event monitor cannot be removed in its own handler")
        await TestWait.until(failureMessage: "Ended sheet must remove its key monitor") { monitor.removals > 0 }
        await TestWait.until(failureMessage: "Escape must retain its decision at the press") { answers == [false] }
        XCTAssertNil(host.attachedSheet)
    }

    func testSheetEndRemovesMonitorBeforeCompletionWithoutHostClose() async throws {
        let host = makeQuestionWindow()
        let restoreWindows = isolateQuestionHost(host)
        host.makeKeyAndOrderFront(nil)
        defer { host.close(); host.contentView = nil; restoreWindows() }
        let monitor = try QuitMonitorRemovalProbe()
        defer { monitor.stop() }
        let completion = try QuitSheetCompletionGate(host: host)
        defer { completion.deliver(.cancel); completion.stop() }
        var answers: [Bool] = []
        let presentation = PendingSaveTermination.present(.saving) { answers.append($0) }
        defer { presentation.dismiss() }
        let sheet = try XCTUnwrap(host.attachedSheet)
        sheet.animationBehavior = .none
        XCTAssertTrue(completion.isHoldingCompletion)
        host.endSheet(sheet, returnCode: .cancel)
        await TestWait.until(failureMessage: "The native sheet must end before host teardown") { host.attachedSheet == nil }
        await TestWait.until(failureMessage: "An ended sheet must remove its monitor before the completion arrives") {
            monitor.removals > 0
        }
        XCTAssertTrue(answers.isEmpty, "The completion remains held independently of native sheet teardown")
        completion.deliver(.cancel)
        await TestWait.until(failureMessage: "Deferred native completion must still reply once") { answers == [false] }
    }

    func testNativeQuitKeyboardChoicesFollowRetitledQuestions() async throws {
        let questions: [PendingSaveTermination.Question] = [.saving, .syncing, .savingAndSyncing, .waitingForRepair]
        for initial in questions {
            for updated in questions {
                for key in ["Escape", "Command-period", "Return"] {
                    try await assertRetitledQuit(initial, updated: updated, key: key)
                }
            }
        }
    }

    func testNativeCancelKeysIgnoreNonShortcutModifiers() async throws {
        for key in ["Shift-Keypad-Function-Escape", "Shift-Keypad-Function-Command-period"] {
            try await assertRetitledQuit(.waitingForRepair, updated: .saving, key: key)
        }
    }

    private func assertRetitledQuit(_ initial: PendingSaveTermination.Question,
                                    updated: PendingSaveTermination.Question, key: String) async throws {
        let host = makeQuestionWindow()
        let restoreWindows = isolateQuestionHost(host)
        host.makeKeyAndOrderFront(nil)
        defer { host.close(); host.contentView = nil; restoreWindows() }
        var answers: [Bool] = []
        let presentation = PendingSaveTermination.present(initial) { answers.append($0) }
        defer { presentation.dismiss() }
        let parent = try XCTUnwrap(NSApp.windows.first { $0.attachedSheet != nil })
        let sheet = try XCTUnwrap(parent.attachedSheet)
        sheet.animationBehavior = .none
        XCTAssertTrue(presentation.update(updated))
        sheet.contentView?.layoutSubtreeIfNeeded()
        try assertQuitKeyboardBindings(updated, in: sheet)
        assertQuestionText(updated, in: Self.views(try XCTUnwrap(sheet.contentView)))
        try sendQuitKey(key, to: sheet)
        await TestWait.until(failureMessage: "Native \(key) choice did not resolve") { !answers.isEmpty }
        _ = try XCTUnwrap(answers.first, "Native key routing must deliver a response")
        XCTAssertEqual(answers, [key == "Return" && updated == .waitingForRepair],
            "\(initial) → \(updated): \(key) must answer the button now shown")
        XCTAssertNil(parent.attachedSheet)
    }

    func chooseNativeQuit(_ choice: String, sheet: NSWindow, parent: NSWindow, buttons: [NSButton]) throws {
        switch choice {
        case "Escape", "Command-period": try sendQuitKey(choice, to: sheet)
        case "Close host": parent.close()
        case "Default": try pressDefault(in: sheet)
        default: try XCTUnwrap(buttons.first { $0.title == choice }).performClick(nil)
        }
    }

    func sendQuitKey(_ key: String, to sheet: NSWindow) throws {
        let escape = key.contains("Escape")
        let characters = escape ? "\u{1b}" : key == "Return" ? "\r" : "."
        var modifiers: NSEvent.ModifierFlags = key.contains("Command-period") ? .command : []
        if key.contains("Shift") { modifiers.insert(.shift) }
        if key.contains("Keypad") { modifiers.insert(.numericPad) }
        if key.contains("Function") { modifiers.insert(.function) }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: modifiers, timestamp: 0,
            windowNumber: sheet.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false,
            keyCode: escape ? 53 : key == "Return" ? 36 : 47))
        NSApp.sendEvent(event)
    }

    func testShownQuitQuestionTracksPendingSaveAndSyncStep() async throws {
        for startsWithStep in [true, false] {
            let h = try ManifestSaveFixture()
            let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
            defer { lock.release(); h.cleanup() }
            h.categories.rename(h.local, to: "Waiting", context: h.context)
            let steps = SyncStepModel(), quit = PendingSaveTermination(delay: 0)
            var step = startsWithStep ? steps.begin() : nil
            defer { if let step { steps.finish(step) } }
            let window = makeQuestionWindow()
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
        case .waitingForRepair:
            return strings.contains("A change is waiting for the library file to be repaired.")
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
