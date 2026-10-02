import AppKit

/// The stock unsaved-changes sheet, verbatim: Apple's copy, the three buttons in Apple's order,
/// Return for Save, Escape for Cancel, ⌘D for Don't Save (TextEdit's key). A sheet on the key window when
/// one is on screen (the History sheet's own window when it is up), else the main window, else a modal
/// alert (a quit from the menu bar extra with the window closed). Presented on the next turn of the run
/// loop: the question can be raised from a SwiftUI change handler, and a sheet must not begin mid-update.
enum UnsavedChangesAlert {
    static func make(fileName: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to “\(fileName)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        let discard = alert.addButton(withTitle: "Don’t Save")
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = [.command]
        return alert
    }

    static func choice(for response: NSApplication.ModalResponse) -> UnsavedChangesChoice {
        switch response {
        case .alertFirstButtonReturn: .save
        case .alertThirdButtonReturn: .discard
        default: .cancel
        }
    }

    /// The sheet on `window`, answered through `resolve` one turn after it has left: AppKit runs the
    /// completion handler while the sheet is still attached, and a continuation that closes the window
    /// (`performClose` beeps at a window with a sheet) or raises the next question must wait for the
    /// dismissal to finish (found live before the freeze; `testTheAnswerArrivesAfterTheSheetHasLeft`).
    /// The host can go away under the sheet — a SwiftUI sheet torn down when its row vanishes in a rebuild —
    /// and AppKit then never runs the completion, so the question would stay open for the life of the process
    /// with every way out refused, quit included: the host's will-close ends the sheet as Cancel, which runs it
    /// (batch Layer-2; `testAHostClosingUnderTheSheetAnswersCancel`).
    static func beginSheet(_ alert: NSAlert, on window: NSWindow,
                           resolve: @escaping (UnsavedChangesChoice) -> Void) {
        var willClose: NSObjectProtocol?
        willClose = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            if window.attachedSheet === alert.window { window.endSheet(alert.window, returnCode: .cancel) }
        }
        alert.beginSheetModal(for: window) { response in
            if let willClose { NotificationCenter.default.removeObserver(willClose) }
            DispatchQueue.main.async { resolve(choice(for: response)) }
        }
    }

    /// The library's presenter (`SkillLibraryViewModel.unsavedChangesPresenter`), wired in `PensieveApp.init`.
    /// The host is the key window when it is the main window or a sheet on it (the History sheet asks over
    /// itself); an unrelated key window — Settings, the New Skill sheet — yields to the main window. A question
    /// raised while another app is frontmost (Quit from the menu bar extra or the Dock with a dirty draft) would
    /// otherwise attach behind that app and park the quit in `.terminateLater` unseen: the app activates and
    /// brings the host forward first, as NSDocument does (batch Layer-2).
    static func present(_ prompt: UnsavedChangesPrompt, resolve: @escaping (UnsavedChangesChoice) -> Void) {
        DispatchQueue.main.async {
            let alert = make(fileName: prompt.fileName)
            let main = WindowPolicy.mainWindow(among: NSApp.windows).flatMap { $0.isVisible ? $0 : nil }
            let key = NSApp.keyWindow.flatMap { window in
                window.isVisible && (window === main || window.sheetParent === main) ? window : nil
            }
            NSApp.activate(ignoringOtherApps: true)
            guard var window = key ?? main else {
                resolve(choice(for: alert.runModal()))
                return
            }
            // A sheet queues behind one already attached (History over the main window while Settings was key):
            // host on the innermost sheet, where the question is seen at once (batch Layer-2, round 4).
            while let sheet = window.attachedSheet { window = sheet }
            window.makeKeyAndOrderFront(nil)
            beginSheet(alert, on: window, resolve: resolve)
        }
    }
}
