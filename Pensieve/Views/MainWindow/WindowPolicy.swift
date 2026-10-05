import AppKit

/// Window policy for the production app. Pensieve keeps one main window and one update-review window: macOS's automatic
/// window tabbing would still offer View › Show Tab Bar and a + that opens a second main window, each with
/// its own selection and import state, restored across launches. Applied before any window exists.
enum WindowPolicy {
    static func apply() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    static let changesWindowID = "view-changes"

    static func configureChangesWindow(_ window: NSWindow) {
        window.identifier = NSUserInterfaceItemIdentifier(changesWindowID)
        window.setAccessibilityIdentifier(changesWindowID)
        window.isRestorable = false
        window.tabbingMode = .disallowed
    }

    static func showChangesWindow(among windows: [NSWindow], open: () -> Void) {
        if let window = windows.first(where: {
            ($0.isVisible || $0.isMiniaturized) && $0.identifier?.rawValue == changesWindowID
        }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            open()
        }
    }

    /// The `WindowGroup(id: "main")` window AppKit already holds — on screen or minimized — or nil. SwiftUI
    /// names the group's windows `main-AppWindow-N`; sheets, panels, and Settings never match. Callers
    /// bring this window forward instead of asking the group for another (`openWindow(id:)` on a
    /// value-less group always creates one).
    static func mainWindow(among windows: [NSWindow]) -> NSWindow? {
        windows.first { window in
            (window.isVisible || window.isMiniaturized)
                && window.identifier?.rawValue.hasPrefix("main-") == true
        }
    }

    /// Every main window after the first, in AppKit's order. SwiftUI reopens each main window that was
    /// open at the last quit; with tabbing off, a second one restored from the tabbed days would stand
    /// beside the first. The delegate closes these once launch finishes.
    static func extraMainWindows(among windows: [NSWindow]) -> [NSWindow] {
        let mains = windows.filter { $0.identifier?.rawValue.hasPrefix("main-") == true }
        return Array(mains.dropFirst())
    }

    /// Bring the existing main window forward, or ask `open` for one when none exists.
    static func showMainWindow(among windows: [NSWindow], open: () -> Void) {
        if let window = mainWindow(among: windows) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            open()
        }
    }
}
