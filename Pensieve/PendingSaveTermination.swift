import AppKit

/// Holds AppKit's deferred quit while manifest saves and sync writes finish.
@MainActor
final class PendingSaveTermination {
    private var generation = 0
    private(set) var isWaiting = false
    private let delay: TimeInterval
    private let presenter: (@escaping (Bool) -> Void) -> (() -> Void)
    private let stepPresenter: (@escaping (Bool) -> Void) -> (() -> Void)

    init(delay: TimeInterval = 5,
         presentStep: @escaping (@escaping (Bool) -> Void) -> (() -> Void) = PendingSaveTermination.presentSyncStep,
         present: @escaping (@escaping (Bool) -> Void) -> (() -> Void) = PendingSaveTermination.present) {
        self.delay = delay
        self.presenter = present
        self.stepPresenter = presentStep
    }
    private var dismiss: (() -> Void)?
    private var askAgain: (() -> Void)?
    private var questionScheduled = false

    func wait(for saves: ManifestSaveModel?, steps: SyncStepModel? = nil, reply: @escaping (Bool) -> Void) {
        isWaiting = true
        generation += 1
        let request = generation
        Task { @MainActor in
            while Self.hasPending(saves, steps) {
                await steps?.waitUntilIdle()
                await saves?.waitUntilIdle()
            }
            guard generation == request else { return }
            finish(true, reply: reply)
        }
        questionScheduled = true
        askAgain = { [weak self] in self?.showQuestion(for: saves, steps: steps, request: request, reply: reply) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard generation == request, questionScheduled else { return }
            showQuestion(for: saves, steps: steps, request: request, reply: reply)
        }
    }

    /// Another Quit reopens the question for the original deferred request, without a timer after Wait.
    func requestQuestion() { askAgain?() }

    private static func hasPending(_ saves: ManifestSaveModel?, _ steps: SyncStepModel?) -> Bool {
        (saves?.pendingCount ?? 0) > 0 || (steps?.pendingCount ?? 0) > 0
    }

    private func showQuestion(for saves: ManifestSaveModel?, steps: SyncStepModel?, request: Int,
                              reply: @escaping (Bool) -> Void) {
        guard generation == request, Self.hasPending(saves, steps), dismiss == nil else { return }
        questionScheduled = false
        var answered = false
        let present: (@escaping (Bool) -> Void) -> (() -> Void)
        if (saves?.pendingCount ?? 0) > 0 && (steps?.pendingCount ?? 0) > 0 {
            present = Self.presentSaveAndSyncStep
        } else {
            present = (steps?.pendingCount ?? 0) > 0 ? stepPresenter : presenter
        }
        dismiss = present { [weak self] quitAnyway in
            guard let self, self.generation == request, !answered else { return }
            answered = true
            if quitAnyway { self.finish(true, reply: reply) } else {
                let close = self.dismiss
                self.dismiss = nil
                close?()
            }
        }
    }

    private func finish(_ quit: Bool, reply: (Bool) -> Void) {
        generation += 1
        isWaiting = false
        askAgain = nil
        questionScheduled = false
        let close = dismiss
        dismiss = nil
        close?()
        reply(quit)
    }

    static func present(_ resolve: @escaping (Bool) -> Void) -> (() -> Void) {
        present(message: "Pensieve is still saving a change.",
                detail: "It's waiting for sync to finish. If you quit now, the change won't be saved.", resolve: resolve)
    }

    static func presentSyncStep(_ resolve: @escaping (Bool) -> Void) -> (() -> Void) {
        present(message: "Pensieve is still finishing a sync step.",
                detail: "If you quit now, it stops partway.", resolve: resolve)
    }

    private static func presentSaveAndSyncStep(_ resolve: @escaping (Bool) -> Void) -> (() -> Void) {
        present(message: "Pensieve is still finishing a sync step and saving a change.",
                detail: "If you quit now, the sync step stops partway and the change won't be saved.", resolve: resolve)
    }

    private static func present(message: String, detail: String,
                                resolve: @escaping (Bool) -> Void) -> (() -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.addButton(withTitle: "Wait")
        alert.addButton(withTitle: "Quit Anyway")
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
        alert.beginSheetModal(for: host) { response in
            if let willClose { NotificationCenter.default.removeObserver(willClose) }
            DispatchQueue.main.async {
                if temporary { host.close() }
                resolve(response == .alertSecondButtonReturn)
            }
        }
        return {
            host.endSheet(alert.window)
            alert.window.orderOut(nil)
            if temporary { host.close() }
        }
    }
}
