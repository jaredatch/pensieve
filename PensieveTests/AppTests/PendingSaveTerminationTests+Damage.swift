import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

extension PendingSaveTerminationTests {
    func testDamagedUnconfiguredLibraryRendersRepairLineThroughSyncStatusView() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "damaged")
        await h.saves.refreshDamage()
        let model = SyncModel(git: TestPaths.git, root: h.root, initialState: .unconfigured)
        XCTAssertEqual(h.saves.pendingCount, 0)
        let host = NSHostingView(rootView: AnyView(SyncStatusView(model: model, saves: h.saves,
            onResolve: { XCTFail("Damage must offer repair") })
            .modelContainer(h.context.container).frame(width: 400, height: 80)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = host
        window.orderFront(nil)
        defer { window.close(); window.contentView = nil }
        await TestWait.until(failureMessage: "SyncStatusView must render Library file damaged without sync or queued saves") {
            RenderedViewTestSupport.values(in: host).compactMap { $0 as? Text }
                .flatMap { RenderedViewTestSupport.strings(in: $0) }.contains("Library file damaged")
        }
    }

    func testWaitReplyAfterRepairPauseReopensTheRepairQuestion() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { lock.release() }
        h.categories.rename(h.local, to: "Waiting", context: h.context)
        var questions: [PendingSaveTermination.Question] = []
        var replies: [Bool] = []
        var answers: [(Bool) -> Void] = []
        var refusedUpdates = 0
        let quit = PendingSaveTermination(delay: 0) { question, answer in
            questions.append(question)
            answers.append(answer)
            return .init(update: { _ in refusedUpdates += 1; return false }, dismiss: {})
        }
        quit.wait(for: h.saves) { replies.append($0) }
        await TestWait.until(failureMessage: "Saving question must appear") { answers.count == 1 }
        // The native presenter has recorded Wait, but has not delivered its deferred reply.
        try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "damaged")
        lock.release()
        await h.saves.waitUntilIdle()
        await TestWait.until(failureMessage: "The recorded question must refuse the late repair update") { refusedUpdates > 0 }
        try XCTUnwrap(answers.first)(false)
        XCTAssertEqual(questions, [.saving, .waitingForRepair], "Wait must continue the pending Quit into repair")
        XCTAssertTrue(replies.isEmpty)
        quit.requestQuestion()
        try XCTUnwrap(answers.last)(false)
        XCTAssertEqual(replies, [false])
    }

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

/// Holds only this host's native completion at NSWindow.beginSheet. AppKit still presents and
/// ends the real sheet; the gate does not synthesize notifications, buttons, or monitor removals.
final class QuitSheetCompletionGate {
    private let method: Method
    private let original: IMP
    private var replacement: IMP?
    private var completion: AnyObject?
    var isHoldingCompletion: Bool { completion != nil }

    init(host: NSWindow) throws {
        let selector = NSSelectorFromString("beginSheet:completionHandler:")
        method = try XCTUnwrap(class_getInstanceMethod(NSWindow.self, selector))
        original = method_getImplementation(method)
        typealias Begin = @convention(c) (NSWindow, Selector, NSWindow, AnyObject?) -> Void
        let begin = unsafeBitCast(original, to: Begin.self)
        typealias Block = @convention(block) (NSWindow, NSWindow, AnyObject?) -> Void
        let block: Block = { [weak self, weak host] receiver, sheet, callback in
            if let self, receiver === host {
                if let callback { self.completion = (callback as? NSCopying)?.copy(with: nil) as AnyObject? }
                begin(receiver, selector, sheet, nil)
            } else { begin(receiver, selector, sheet, callback) }
        }
        let replacement = imp_implementationWithBlock(block)
        self.replacement = replacement
        method_setImplementation(method, replacement)
    }

    func deliver(_ response: NSApplication.ModalResponse) {
        guard let completion else { return }
        self.completion = nil
        typealias Completion = @convention(block) (Int) -> Void
        unsafeBitCast(completion, to: Completion.self)(response.rawValue)
    }

    func stop() {
        guard let replacement else { return }
        method_setImplementation(method, original)
        imp_removeBlock(replacement)
        self.replacement = nil
    }
    deinit { stop() }
}

/// Wraps the first key-down monitor registered by the presenter and observes removal of that
/// same token. The handler's exact dynamic extent is measured, not all of NSApp.sendEvent.
/// AppKit's other monitors and every native return value are preserved.
final class QuitMonitorRemovalProbe {
    private(set) var removals = 0
    private(set) var reentrantRemovals = 0
    private(set) var sawKeyHandler = false
    private var handling = false
    private var token: AnyObject?
    private var registered = false
    private struct Hook {
        let method: Method
        let original: IMP
        let replacement: IMP
    }
    private var hooks: [Hook] = []

    init() throws {
        try observeRegistration()
        try observeRemoval()
    }

    private func observeRegistration() throws {
        let selector = NSSelectorFromString("addLocalMonitorForEventsMatchingMask:handler:")
        let method = try XCTUnwrap(class_getClassMethod(NSEvent.self, selector))
        let original = method_getImplementation(method)
        typealias Add = @convention(c) (AnyObject, Selector, UInt64, AnyObject) -> AnyObject?
        typealias AddBlock = @convention(block) (AnyObject, UInt64, AnyObject) -> AnyObject?
        typealias Handler = @convention(block) (NSEvent) -> NSEvent?
        let add = unsafeBitCast(original, to: Add.self)
        let block: AddBlock = { [weak self] receiver, mask, callback in
            guard let self, !self.registered, mask == NSEvent.EventTypeMask.keyDown.rawValue else {
                return add(receiver, selector, mask, callback)
            }
            self.registered = true
            let handler = unsafeBitCast(callback, to: Handler.self)
            let wrapped: Handler = { [weak self] event in
                self?.sawKeyHandler = true
                self?.handling = true
                defer { self?.handling = false }
                return handler(event)
            }
            let token = add(receiver, selector, mask, unsafeBitCast(wrapped, to: AnyObject.self))
            self.token = token
            return token
        }
        let replacement = imp_implementationWithBlock(block)
        hooks.append(Hook(method: method, original: original, replacement: replacement))
        method_setImplementation(method, replacement)
    }

    private func observeRemoval() throws {
        let selector = NSSelectorFromString("removeMonitor:")
        let method = try XCTUnwrap(class_getClassMethod(NSEvent.self, selector))
        let original = method_getImplementation(method)
        typealias Remove = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        typealias Block = @convention(block) (AnyObject, AnyObject) -> Void
        let remove = unsafeBitCast(original, to: Remove.self)
        let block: Block = { [weak self] receiver, token in
            if let self, token === self.token {
                self.removals += 1
                if self.handling { self.reentrantRemovals += 1 }
            }
            remove(receiver, selector, token)
        }
        let replacement = imp_implementationWithBlock(block)
        hooks.append(Hook(method: method, original: original, replacement: replacement))
        method_setImplementation(method, replacement)
    }

    func stop() {
        for hook in hooks.reversed() {
            method_setImplementation(hook.method, hook.original)
            imp_removeBlock(hook.replacement)
        }
        hooks = []
        token = nil
    }
    deinit { stop() }
}
