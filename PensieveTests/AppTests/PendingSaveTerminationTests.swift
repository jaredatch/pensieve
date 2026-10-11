import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class PendingSaveTerminationTests: XCTestCase {
    func testWaitingNoticeAppearsAfterFiveSecondsAndQuitCompletesWhenSaveLands() async throws {
        let h = try ManifestSaveFixture(waitSeconds: 5)
        defer { h.cleanup() }
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { lock.release() }
        let host = NSHostingView(rootView: AnyView(SyncStatusView(model: SyncModel(git: TestPaths.git, root: h.root,
            initialState: .conflicted(["skills/alpha/SKILL.md"])),
            saves: h.saves, onResolve: {}).modelContainer(h.context.container).frame(width: 400, height: 80)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func waitingLineIsRendered() -> Bool {
            RenderedViewTestSupport.values(in: host).compactMap { $0 as? Text }
                .flatMap { RenderedViewTestSupport.strings(in: $0) }.contains(ManifestSaveModel.waitingMessage)
        }
        XCTAssertFalse(waitingLineIsRendered())
        let started = Date()
        h.categories.rename(h.local, to: "Saved", context: h.context)
        XCTAssertNil(h.saves.statusMessage)
        var choices: ((Bool) -> Void)?
        var dismissed = false
        let quit = PendingSaveTermination(present: { _, resolve in
            choices = resolve; return .init(update: { _ in true }, dismiss: { dismissed = true })
        })
        var replies: [Bool] = []
        let answer = PensieveAppDelegate.terminationReply(hasUnsavedChanges: false, questionOpen: false,
            confirm: { _ in XCTFail("There is no unsaved editor draft") }, reply: { replies.append($0) },
            saves: h.saves, saveTermination: quit)
        XCTAssertEqual(answer, .terminateLater)
        XCTAssertTrue(replies.isEmpty)
        await TestWait.until(failureMessage: "The delayed save notice and quit prompt did not appear") {
            h.saves.statusMessage != nil && choices != nil && waitingLineIsRendered()
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 4.9)
        XCTAssertEqual(h.saves.statusMessage, "Your change will save when sync finishes.")
        let rendered = RenderedViewTestSupport.values(in: host).compactMap { $0 as? Text }
            .flatMap { RenderedViewTestSupport.strings(in: $0) }
        XCTAssertTrue(rendered.contains("1 conflict"), "Waiting must retain the conflict action")
        XCTAssertTrue(replies.isEmpty)
        lock.release()
        await TestWait.until(failureMessage: "Quit did not complete after the save") { replies == [true] }
        XCTAssertTrue(dismissed)
        XCTAssertNil(h.saves.statusMessage)
        await TestWait.until(failureMessage: "The rendered waiting line did not clear") { !waitingLineIsRendered() }
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root).categories.first?.name, "Saved")
        choices?(true)
        XCTAssertEqual(replies, [true], "A late alert callback cannot answer quit twice")
    }

    func testWaitKeepsAppRunningAndQuitAnywayCompletesWhileSaveStillWaits() async throws {
        for outcome in ["save after Wait", "Quit Anyway after Wait", "Quit Anyway", "early Wait"] {
            let h = try ManifestSaveFixture()
            defer { h.cleanup() }
            let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
            defer { lock.release() }
            h.categories.rename(h.local, to: "Waiting", context: h.context)
            var questions: [(Bool) -> Void] = []
            var dismissals = 0
            let early = outcome == "early Wait"
            let quit = PendingSaveTermination(delay: early ? 0.5 : 0.05) { _, resolve in
                questions.append(resolve); return .init(update: { _ in true }, dismiss: { dismissals += 1 })
            }
            var replies: [Bool] = []
            beginQuit(saves: h.saves, quit: quit, reply: { replies.append($0) })
            if early { await requestEarlyQuit(saves: h.saves, quit: quit) }
            await TestWait.until(failureMessage: "Quit did not ask about the waiting save") { !questions.isEmpty }
            let first = try XCTUnwrap(questions.first), quitAnyway = outcome == "Quit Anyway"
            first(quitAnyway)
            XCTAssertEqual(dismissals, 1)
            XCTAssertEqual(replies, quitAnyway ? [true] : [], "Wait must leave AppKit's quit deferred")
            XCTAssertEqual(quit.isWaiting, !quitAnyway)
            try assertSavePending(h)
            first(!quitAnyway)
            XCTAssertEqual(replies, quitAnyway ? [true] : [], "A dismissed question cannot answer again")
            if !quitAnyway {
                // More than one initial delay passes quietly until another quit is requested.
                try await Task.sleep(nanoseconds: early ? 650_000_000 : 150_000_000)
                XCTAssertEqual(questions.count, 1, "Wait must not repeatedly interrupt the user")
                let repeated = repeatQuit(saves: h.saves, quit: quit)
                XCTAssertEqual(repeated, .terminateCancel)
                await TestWait.until(failureMessage: "Quit Anyway became unreachable after Wait") { questions.count == 2 }
                XCTAssertTrue(replies.isEmpty, "The original quit must stay deferred between questions")
                XCTAssertEqual(h.saves.pendingCount, 1)
                guard questions.count == 2 else { lock.release(); await h.saves.waitUntilIdle(); continue }
                _ = repeatQuit(saves: h.saves, quit: quit)
                XCTAssertEqual(questions.count, 2, "Another quit cannot create a second simultaneous sheet")
                first(true)
                XCTAssertTrue(replies.isEmpty, "The old question cannot answer the renewed question")
                if outcome == "Quit Anyway after Wait" {
                    questions[1](true)
                    XCTAssertEqual(replies, [true], "Quit Anyway must finish the original quit while the lock stays held")
                    XCTAssertFalse(quit.isWaiting)
                }
            }
            lock.release()
            await h.saves.waitUntilIdle()
            await TestWait.until(failureMessage: "The deferred quit did not finish") { !replies.isEmpty }
            XCTAssertEqual(replies, [true], "Wait must complete the original quit when the save lands")
            XCTAssertFalse(quit.isWaiting)
            XCTAssertEqual(dismissals, quitAnyway ? 1 : 2)
        }
    }

    private func requestEarlyQuit(saves: ManifestSaveModel, quit: PendingSaveTermination) async {
        await TestWait.until(failureMessage: "Quit never began waiting") { quit.isWaiting }
        _ = repeatQuit(saves: saves, quit: quit)
    }

    private func beginQuit(saves: ManifestSaveModel, quit: PendingSaveTermination, reply: @escaping (Bool) -> Void) {
        let answer = PensieveAppDelegate.terminationReply(hasUnsavedChanges: false, questionOpen: false,
            confirm: { _ in XCTFail("No draft") }, reply: reply, saves: saves, saveTermination: quit)
        XCTAssertEqual(answer, .terminateLater)
    }

    private func assertSavePending(_ h: ManifestSaveFixture) throws {
        XCTAssertEqual(h.saves.pendingCount, 1)
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root).categories.first?.name, "Local")
    }

    private func repeatQuit(saves: ManifestSaveModel, quit: PendingSaveTermination) -> NSApplication.TerminateReply {
        PensieveAppDelegate.terminationReply(hasUnsavedChanges: false, questionOpen: false,
            confirm: { _ in XCTFail("No draft") }, reply: { _ in XCTFail("Only the original quit is answered") },
            saves: saves, saveTermination: quit)
    }

    func testNativeQuitQuestionButtonsAndHostClosureResolve() async throws {
        let unrelated = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 300, height: 150),
            styleMask: [.titled], backing: .buffered, defer: false)
        unrelated.isReleasedWhenClosed = false
        unrelated.animationBehavior = .none
        unrelated.title = "Unrelated visible test host"
        defer { unrelated.close() }
        for (step, choice) in [false, true].flatMap({ step in
            ["Wait", "Quit Anyway", "Close host"].map { (step, $0) }
        }) {
            unrelated.orderFront(nil)
            XCTAssertTrue(unrelated.isVisible)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            defer { window.close() }
            window.makeKeyAndOrderFront(nil)
            var answers: [Bool] = []
            let presentation = PendingSaveTermination.present(step ? .syncing : .saving) { answers.append($0) }
            defer { presentation.dismiss() }
            let parent = try XCTUnwrap(NSApp.windows.first { $0.attachedSheet != nil })
            let sheet = try XCTUnwrap(parent.attachedSheet)
            sheet.animationBehavior = .none
            await TestWait.until(failureMessage: "The native quit question never rendered its controls") {
                sheet.contentView?.layoutSubtreeIfNeeded()
                return sheet.contentView.map { Self.views($0).compactMap { $0 as? NSButton }.count == 2 } ?? false
            }
            let rendered = Self.views(try XCTUnwrap(sheet.contentView))
            let strings = rendered.compactMap { ($0 as? NSTextField)?.stringValue }
            XCTAssertTrue(strings.contains(step ? "Pensieve is still finishing a sync step."
                : "Pensieve is still saving a change."))
            XCTAssertTrue(strings.contains(step ? "If you quit now, it stops partway."
                : "It's waiting for sync to finish. If you quit now, the change won't be saved."))
            let buttons = rendered.compactMap { $0 as? NSButton }
            XCTAssertEqual(Set(buttons.map(\.title)), ["Wait", "Quit Anyway"])
            if choice == "Close host" { parent.close() } else {
                try XCTUnwrap(buttons.first { $0.title == choice }).performClick(nil)
            }
            await TestWait.until(failureMessage: "The native quit choice did not resolve") { !answers.isEmpty }
            XCTAssertEqual(answers, [choice == "Quit Anyway"])
            XCTAssertNil(parent.attachedSheet)
            XCTAssertFalse(presentation.update(.savingAndSyncing), "A detached question cannot show another warning")
        }
        for choice in ["Wait", "Quit Anyway", "Close host"] {
            unrelated.orderFront(nil)
            XCTAssertTrue(unrelated.isVisible)
            try await assertBothPendingQuestion(choice: choice, stray: unrelated)
        }
    }

    private func assertBothPendingQuestion(choice: String, stray: NSWindow) async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { lock.release() }
        h.categories.rename(h.local, to: "Waiting", context: h.context)
        let steps = SyncStepModel()
        let step = steps.begin()
        defer { steps.finish(step) }
        let restoreWindows = isolateQuestionHost(stray)
        defer { restoreWindows() }
        XCTAssertEqual(NSApp.windows.filter(\.isVisible), [stray])
        let quit = PendingSaveTermination(delay: 0)
        var answers: [Bool] = []
        quit.wait(for: h.saves, steps: steps) { answers.append($0) }
        await TestWait.until(failureMessage: "The combined quit question did not appear") {
            NSApp.windows.contains { $0.attachedSheet != nil }
        }
        let parent = try XCTUnwrap(NSApp.windows.first { $0.attachedSheet != nil })
        XCTAssertTrue(parent === stray, "The combined question must exercise the stray window on every host")
        let sheet = try XCTUnwrap(parent.attachedSheet)
        sheet.animationBehavior = .none
        await TestWait.until(failureMessage: "The combined quit question never rendered its controls") {
            sheet.contentView?.layoutSubtreeIfNeeded()
            return sheet.contentView.map { Self.views($0).compactMap { $0 as? NSButton }.count == 2 } ?? false
        }
        let rendered = Self.views(try XCTUnwrap(sheet.contentView))
        let strings = rendered.compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(strings.contains("Pensieve is still finishing a sync step and saving a change."))
        XCTAssertTrue(strings.contains("If you quit now, the sync step stops partway and the change won't be saved."))
        let buttons = rendered.compactMap { $0 as? NSButton }
        XCTAssertEqual(Set(buttons.map(\.title)), ["Wait", "Quit Anyway"])
        if choice == "Close host" { parent.close() } else {
            try XCTUnwrap(buttons.first { $0.title == choice }).performClick(nil)
        }
        await TestWait.until(failureMessage: "The combined quit question did not close") {
            parent.attachedSheet == nil && (choice != "Quit Anyway" || !quit.isWaiting)
        }
        XCTAssertEqual(answers, choice == "Quit Anyway" ? [true] : [])
        XCTAssertEqual(quit.isWaiting, choice != "Quit Anyway")
        try assertSavePending(h)
        lock.release()
        steps.finish(step)
        await h.saves.waitUntilIdle()
        await TestWait.until(failureMessage: "The combined deferred quit did not finish") { answers == [true] }
    }

    static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    private func isolateQuestionHost(_ stray: NSWindow) -> () -> Void {
        let previousWindows = NSApp.windows.filter { $0.isVisible && $0 !== stray }
        let previousAnimations = previousWindows.map(\.animationBehavior)
        previousWindows.forEach { $0.animationBehavior = .none; $0.orderOut(nil) }
        return {
            for (window, behavior) in zip(previousWindows, previousAnimations) {
                window.orderFront(nil)
                window.animationBehavior = behavior
            }
        }
    }
}
