import AppKit

/// Holds AppKit's deferred quit while the process-owned manifest queue drains.
@MainActor
final class PendingSaveTermination {
    private var generation = 0
    private(set) var isWaiting = false
    private let delay: TimeInterval
    private let presenter: (@escaping (Bool) -> Void) -> (() -> Void)

    init(delay: TimeInterval = 5,
         present: @escaping (@escaping (Bool) -> Void) -> (() -> Void) = PendingSaveTermination.present) {
        self.delay = delay
        self.presenter = present
    }
    private var dismiss: (() -> Void)?

    func wait(for saves: ManifestSaveModel, reply: @escaping (Bool) -> Void) {
        isWaiting = true
        generation += 1
        let request = generation
        Task { @MainActor in
            await saves.waitUntilIdle()
            guard generation == request else { return }
            finish(true, reply: reply)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard generation == request, saves.pendingCount > 0 else { return }
            var answered = false
            dismiss = presenter { [weak self] quitAnyway in
                guard let self, self.generation == request, !answered else { return }
                answered = true
                if quitAnyway { self.finish(true, reply: reply) } else {
                    let close = self.dismiss
                    self.dismiss = nil
                    close?()
                }
            }
        }
    }

    private func finish(_ quit: Bool, reply: (Bool) -> Void) {
        generation += 1
        isWaiting = false
        let close = dismiss
        dismiss = nil
        close?()
        reply(quit)
    }

    static func present(_ resolve: @escaping (Bool) -> Void) -> (() -> Void) {
        let alert = NSAlert()
        alert.messageText = "Pensieve is still saving a change."
        alert.informativeText = "It's waiting for sync to finish. If you quit now, the change won't be saved."
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
