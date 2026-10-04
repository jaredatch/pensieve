import AppKit
import SwiftUI

/// Vetoes the main window's close while an editor draft is unsaved. This AppKit bridge remains
/// from macOS 14, when SwiftUI had no close hook: a proxy becomes the window's delegate, answers
/// `windowShouldClose(_:)`, and forwards every other delegate method to the delegate SwiftUI installed.
/// Mounted as a background view of the main window's content. `shouldClose` returns false and starts the
/// question when there is one; the answer's Save or Don't Save asks the window to close again through
/// `performClose`, which reaches this proxy once more, finds nothing unsaved, and hands the close to
/// SwiftUI's delegate — never `NSWindow.close()`, which would skip SwiftUI's scene bookkeeping and leave
/// a window that cannot be reopened (found live before the freeze).
struct WindowCloseGuard: NSViewRepresentable {
    let shouldClose: (NSWindow) -> Bool

    func makeCoordinator() -> WindowDelegateProxy { WindowDelegateProxy() }

    func makeNSView(context: Context) -> WindowGuardView {
        let view = WindowGuardView(frame: .zero)
        view.proxy = context.coordinator
        return view
    }

    func updateNSView(_ view: WindowGuardView, context: Context) {
        context.coordinator.shouldClose = shouldClose
        context.coordinator.attach(to: view.window)   // SwiftUI may have replaced the delegate since
    }
}

/// Knows when it lands in a window: `viewDidMoveToWindow` fires whenever the hierarchy is placed, whether
/// or not SwiftUI updates the representable, so the proxy attaches without waiting for an input change.
final class WindowGuardView: NSView {
    weak var proxy: WindowDelegateProxy?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        proxy?.attach(to: window)
    }
}

final class WindowDelegateProxy: NSObject, NSWindowDelegate {
    var shouldClose: (NSWindow) -> Bool = { _ in true }
    /// The delegate the window had — SwiftUI's. Held strongly: AppKit records which delegate methods exist
    /// when the delegate is set, and every forwarded call must still find its target.
    private(set) var original: NSWindowDelegate?
    private(set) weak var window: NSWindow?

    func attach(to window: NSWindow?) {
        guard let window, window.delegate !== self else { return }
        original = window.delegate
        self.window = window
        window.delegate = self
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? { original }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shouldClose(sender) else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }
}
