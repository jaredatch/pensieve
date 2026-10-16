import AppKit
import Observation

/// Holds AppKit's deferred quit while manifest saves and sync writes finish.
@MainActor
final class PendingSaveTermination {
    enum Question: Equatable {
        case saving, syncing, savingAndSyncing, waitingForRepair

        func covers(_ current: Question) -> Bool {
            self == current || (self == .savingAndSyncing && current != .waitingForRepair)
        }

        var message: String {
            switch self {
            case .waitingForRepair: return "A change is waiting for the library file to be repaired."
            case .saving: return "Pensieve is still saving a change."
            case .syncing: return "Pensieve is still finishing a sync step."
            case .savingAndSyncing: return "Pensieve is still finishing a sync step and saving a change."
            }
        }

        var detail: String {
            switch self {
            case .waitingForRepair:
                return "It's kept on this Mac and saves when you repair the file here. "
                    + "If another Mac repairs the file first, its version replaces your change."
            case .saving: return "It's waiting for sync to finish. If you quit now, the change won't be saved."
            case .syncing: return "If you quit now, it stops partway."
            case .savingAndSyncing: return "If you quit now, the sync step stops partway and the change won't be saved."
            }
        }
    }

    struct Presentation {
        // False means the native question has closed, so this warning was not shown.
        let update: (Question) -> Bool
        let dismiss: () -> Void
    }

    private var generation = 0
    private(set) var isWaiting = false
    private let delay: TimeInterval
    private let presenter: (Question, @escaping (Bool) -> Void) -> Presentation
    private var presented: Presentation?
    private var shownQuestion: Question?
    private var questionID: UUID?
    private var askAgain: (() -> Void)?
    private var questionScheduled = false

    init(delay: TimeInterval = 5,
         present: @escaping (Question, @escaping (Bool) -> Void) -> Presentation = PendingSaveTermination.present) {
        self.delay = delay
        self.presenter = present
    }

    func wait(for saves: ManifestSaveModel?, steps: SyncStepModel? = nil, reply: @escaping (Bool) -> Void) {
        isWaiting = true
        generation += 1
        let request = generation
        questionScheduled = true
        askAgain = { [weak self] in self?.showQuestion(for: saves, steps: steps, request: request, reply: reply) }
        observePending(saves, steps, request: request, reply: reply)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard generation == request, questionScheduled else { return }
            showQuestion(for: saves, steps: steps, request: request, reply: reply)
        }
    }

    /// Another Quit reopens the question for the original deferred request, without a timer after Wait.
    func requestQuestion() { askAgain?() }

    private static func question(_ saves: ManifestSaveModel?, _ steps: SyncStepModel?) -> Question? {
        switch (saves?.hasActiveSaves == true, (steps?.pendingCount ?? 0) > 0) {
        case (true, true): return .savingAndSyncing
        case (true, false): return .saving
        case (false, true): return .syncing
        case (false, false): return (saves?.pendingCount ?? 0) > 0 ? .waitingForRepair : nil
        }
    }

    private func observePending(_ saves: ManifestSaveModel?, _ steps: SyncStepModel?, request: Int,
                                reply: @escaping (Bool) -> Void) {
        guard generation == request else { return }
        let question = withObservationTracking {
            Self.question(saves, steps)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePending(saves, steps, request: request, reply: reply) }
        }
        guard let question else { finish(true, reply: reply); return }
        if question == .waitingForRepair, questionID == nil {
            showQuestion(for: saves, steps: steps, request: request, reply: reply)
        } else { updateQuestion(question) }
    }

    private func updateQuestion(_ question: Question) {
        guard questionID != nil, shownQuestion != question else { return }
        if presented?.update(question) == true { shownQuestion = question }
    }

    private func showQuestion(for saves: ManifestSaveModel?, steps: SyncStepModel?, request: Int,
                              reply: @escaping (Bool) -> Void) {
        guard generation == request, let question = Self.question(saves, steps), questionID == nil else { return }
        questionScheduled = false
        let id = UUID()
        questionID = id
        shownQuestion = question
        let presentation = presenter(question) { [weak self] quitAnyway in
            guard let self, self.generation == request, self.questionID == id else { return }
            // A native button can be invoked before Observation's queued update. Require consent
            // to any pending kind of work the answered question did not name.
            if quitAnyway, let current = Self.question(saves, steps), self.shownQuestion?.covers(current) != true {
                self.dismissQuestion()
                self.showQuestion(for: saves, steps: steps, request: request, reply: reply)
                return
            }
            if quitAnyway { self.finish(true, reply: reply) } else if self.shownQuestion == .waitingForRepair {
                self.finish(false, reply: reply)
            } else { self.dismissQuestion() }
        }
        if generation == request, questionID == id { presented = presentation } else { presentation.dismiss() }
    }

    private func dismissQuestion() {
        questionID = nil
        shownQuestion = nil
        let close = presented?.dismiss
        presented = nil
        close?()
    }

    private func finish(_ quit: Bool, reply: (Bool) -> Void) {
        generation += 1
        isWaiting = false
        askAgain = nil
        questionScheduled = false
        dismissQuestion()
        reply(quit)
    }

    private static func configureKeys(_ alert: NSAlert, for question: Question) {
        for button in alert.buttons {
            button.keyEquivalent = ""
            button.keyEquivalentModifierMask = []
        }
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = question == .waitingForRepair ? "\u{1b}" : ""
    }

    private static func monitorCancelKeys(_ alert: NSAlert, question: @escaping () -> Question) -> () -> Void {
        // Wait is both the default and the safe choice. A button has only one key equivalent.
        var keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === alert.window else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
            let key = event.charactersIgnoringModifiers
            guard (key == "\u{1b}" && modifiers.isEmpty) || (key == "." && modifiers == .command) else { return event }
            alert.buttons[question() == .waitingForRepair ? 1 : 0].performClick(nil)
            return nil
        }
        return {
            if let monitor = keyMonitor { NSEvent.removeMonitor(monitor); keyMonitor = nil }
        }
    }

    static func present(_ question: Question, resolve: @escaping (Bool) -> Void) -> Presentation {
        var current = question
        let alert = NSAlert()
        alert.messageText = question.message
        alert.informativeText = question.detail
        NSApp.activate(ignoringOtherApps: true)
        alert.addButton(withTitle: question == .waitingForRepair ? "Quit" : "Wait")
        alert.addButton(withTitle: question == .waitingForRepair ? "Cancel" : "Quit Anyway")
        // AppKit owns this native quit question; a sheet allows the save's main-actor completion.
        var parent = NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible }
        while let sheet = parent?.attachedSheet { parent = sheet }
        // A windowless resident gets a temporary sheet parent instead of a blocking modal loop.
        let temporary = parent == nil
        let host = parent ?? NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        if temporary { host.isReleasedWhenClosed = false; host.center() }
        host.makeKeyAndOrderFront(nil)
        var willClose: NSObjectProtocol?
        willClose = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: host, queue: .main
        ) { _ in
            if host.attachedSheet === alert.window { host.endSheet(alert.window, returnCode: .cancel) }
        }
        let stopKeys = monitorCancelKeys(alert) { current }
        alert.beginSheetModal(for: host) { response in
            stopKeys()
            if let willClose { NotificationCenter.default.removeObserver(willClose) }
            DispatchQueue.main.async {
                if temporary { host.close() }
                resolve(response == (current == .waitingForRepair ? .alertFirstButtonReturn : .alertSecondButtonReturn))
            }
        }
        configureKeys(alert, for: question)
        return Presentation(update: { question in
            guard alert.window.sheetParent != nil else { return false }
            current = question
            alert.buttons[0].title = question == .waitingForRepair ? "Quit" : "Wait"
            alert.buttons[1].title = question == .waitingForRepair ? "Cancel" : "Quit Anyway"
            alert.messageText = question.message
            alert.informativeText = question.detail
            alert.layout()
            configureKeys(alert, for: question)
            return true
        }, dismiss: {
            stopKeys()
            host.endSheet(alert.window)
            alert.window.orderOut(nil)
            if temporary { host.close() }
        })
    }
}
