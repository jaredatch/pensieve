import AppKit

/// Narrow AppKit bridge for process/window lifecycle callbacks that SwiftUI's `App` does not expose.
@MainActor
final class PensieveAppDelegate: NSObject, NSApplicationDelegate {
    /// The adaptor-created instance. SwiftUI's `NSApplicationDelegateAdaptor` wraps this object inside
    /// its own internal `NSApp.delegate`, so `NSApplication.shared.delegate as? PensieveAppDelegate` is
    /// always nil — this weak static is the only honest in-process channel to the REAL delegate, and the
    /// test-host guard proof (PLAN-24 / 24.1) unwraps it to assert no `AppRuntime` was ever attached.
    private(set) static weak var shared: PensieveAppDelegate?

    weak var runtime: AppRuntime?

    override init() {
        super.init()
        Self.shared = self
    }

    /// SwiftUI has already restored every main window that was open at the last quit by the time this
    /// runs (probed 2026-09-10: `main-AppWindow-1,main-AppWindow-2` present here; AppKit's
    /// `didFinishRestoringWindows` never fires for them). Close the extras on the next turn of the run
    /// loop, so the group's own setup is done first. Runtime-free: the inert test host takes it too,
    /// where it finds one window at most.
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            WindowPolicy.extraMainWindows(among: NSApp.windows).forEach { $0.close() }
        }
    }

    /// Quit with unsaved changes asks first: `.terminateLater` holds the quit while the stock sheet
    /// is up, and the answer is forwarded to `reply(toApplicationShouldTerminate:)` — Save or Don't Save lets
    /// the quit finish, Cancel keeps the app running.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.terminationReply(
            hasUnsavedChanges: runtime?.library.hasUnsavedChanges ?? false,
            questionOpen: runtime?.library.pendingUnsavedChanges != nil,
            confirm: { then in self.runtime?.library.confirmLeavingAnyDraft(then: then) },
            reply: { sender.reply(toApplicationShouldTerminate: $0) }
        )
    }

    /// The decision apart from `NSApplication`, so a test can drive every arm. A quit while the sheet is
    /// already up is refused outright (`.terminateCancel`) rather than answered from inside the delegate —
    /// checked first, because the draft a question is about can read clean by the time the quit arrives (its
    /// file caught up) and the sheet is still up; otherwise the question is raised on the next turn of the
    /// run loop, so the reply — even one a presenter gives at once — always follows the `.terminateLater`
    /// return, as AppKit's contract requires.
    static func terminationReply(
        hasUnsavedChanges: Bool,
        questionOpen: Bool,
        confirm: @escaping (@escaping (Bool) -> Void) -> Void,
        reply: @escaping (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        guard !questionOpen else { return .terminateCancel }
        guard hasUnsavedChanges else { return .terminateNow }
        DispatchQueue.main.async { confirm(reply) }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        // A minimized main window is not "visible" to AppKit; restore it rather than open a second one.
        WindowPolicy.showMainWindow(among: sender.windows) {
            runtime?.openMainWindow()
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSApp.windows.forEach { $0.makeFirstResponder(nil) }
    }
}
