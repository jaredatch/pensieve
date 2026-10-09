import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class PendingSaveTerminationTests: XCTestCase {
    func testWaitingNoticeAppearsAfterFiveSecondsAndQuitCompletesWhenSaveLands() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { lock.release() }
        let host = NSHostingView(rootView: AnyView(SyncStatusView(model: SyncModel(git: TestPaths.git, root: h.root),
            saves: h.saves, onResolve: {}).modelContainer(h.context.container).frame(width: 400, height: 80)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
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
        let quit = PendingSaveTermination(present: { choices = $0; return { dismissed = true } })
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
        for outcome in ["save after Wait", "Quit Anyway after Wait", "Quit Anyway"] {
            let h = try ManifestSaveFixture()
            defer { h.cleanup() }
            let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
            defer { lock.release() }
            h.categories.rename(h.local, to: "Waiting", context: h.context)
            var questions: [(Bool) -> Void] = []
            var dismissals = 0
            let quit = PendingSaveTermination(delay: 0.05, present: { questions.append($0); return { dismissals += 1 } })
            var replies: [Bool] = []
            let answer = PensieveAppDelegate.terminationReply(hasUnsavedChanges: false, questionOpen: false,
                confirm: { _ in XCTFail("No draft") }, reply: { replies.append($0) }, saves: h.saves, saveTermination: quit)
            XCTAssertEqual(answer, .terminateLater)
            await TestWait.until(failureMessage: "Quit did not ask about the waiting save") { !questions.isEmpty }
            let first = try XCTUnwrap(questions.first)
            let quitAnyway = outcome == "Quit Anyway"
            first(quitAnyway)
            XCTAssertEqual(dismissals, 1)
            XCTAssertEqual(replies, quitAnyway ? [true] : [], "Wait must leave AppKit's quit deferred")
            XCTAssertEqual(quit.isWaiting, !quitAnyway)
            XCTAssertEqual(h.saves.pendingCount, 1)
            XCTAssertEqual(try h.manifest.read(fromRoot: h.root).categories.first?.name, "Local")
            first(!quitAnyway)
            XCTAssertEqual(replies, quitAnyway ? [true] : [], "A dismissed question cannot answer again")
            if !quitAnyway {
                await TestWait.until(failureMessage: "Quit Anyway became unreachable after Wait") { questions.count == 2 }
                XCTAssertTrue(replies.isEmpty, "The original quit must stay deferred between questions")
                XCTAssertEqual(h.saves.pendingCount, 1)
                guard questions.count == 2 else { return }
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

    func testNativeQuitQuestionButtonsAndHostClosureResolve() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        for choice in ["Wait", "Quit Anyway", "Close host"] {
            window.makeKeyAndOrderFront(nil)
            var answers: [Bool] = []
            let dismiss = PendingSaveTermination.present { answers.append($0) }
            let parent = try XCTUnwrap(NSApp.windows.first { $0.attachedSheet != nil })
            let sheet = try XCTUnwrap(parent.attachedSheet)
            let rendered = views(try XCTUnwrap(sheet.contentView))
            let strings = rendered.compactMap { ($0 as? NSTextField)?.stringValue }
            XCTAssertTrue(strings.contains("Pensieve is still saving a change."))
            XCTAssertTrue(strings.contains("It's waiting for sync to finish. If you quit now, the change won't be saved."))
            let buttons = rendered.compactMap { $0 as? NSButton }
            XCTAssertEqual(Set(buttons.map(\.title)), ["Wait", "Quit Anyway"])
            if choice == "Close host" { parent.close() } else {
                try XCTUnwrap(buttons.first { $0.title == choice }).performClick(nil)
            }
            await TestWait.until(failureMessage: "The native quit choice did not resolve") { !answers.isEmpty }
            XCTAssertEqual(answers, [choice == "Quit Anyway"])
            XCTAssertNil(parent.attachedSheet)
            dismiss()
        }
    }
}
