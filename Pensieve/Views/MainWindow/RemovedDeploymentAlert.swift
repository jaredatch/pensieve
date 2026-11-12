import AppKit
import SwiftUI

/// Only this alert waits its turn; the window's existing presentations keep their own ordering.
struct RemovedDeploymentAlert: ViewModifier {
    let notice: RemovedDeploymentNotice
    let blocked: Bool
    @State private var mounted = false

    func body(content: Content) -> some View {
        content
            .background(RemovedDeploymentAlertHost(notice: notice,
                enabled: mounted && !blocked && !notice.entries.isEmpty && notice.presentationID == nil))
            .onAppear { mounted = true }
            .onDisappear { mounted = false }
    }
}

private struct RemovedDeploymentAlertHost: NSViewRepresentable {
    let notice: RemovedDeploymentNotice
    let enabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator(notice: notice) }

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: WindowView, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.attach(to: view.window)
    }

    static func dismantleNSView(_ view: WindowView, coordinator: Coordinator) {
        coordinator.attach(to: nil)
    }

    final class WindowView: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(to: window)
        }
    }

    /// State lifecycle:
    /// | Event | Window/observers | Alert snapshot/claim |
    /// | --- | --- | --- |
    /// | Mount or move | Attach to the actual host window | Try pending entries when visible and free |
    /// | SwiftUI update, including unchanged input | Refresh eligibility; keep observers | Keep any open snapshot |
    /// | Another sheet ends, or window opens | Recheck actual attachedSheet | Present all current entries |
    /// | OK | Keep attachment | Clear only shown IDs, release claim, try later entries |
    /// | Close, detach or teardown | Remove observers, abort own sheet | Release claim without acknowledging |
    @MainActor
    final class Coordinator {
        var enabled = false
        private let notice: RemovedDeploymentNotice
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var alert: NSAlert?
        private var scheduled = false

        init(notice: RemovedDeploymentNotice) { self.notice = notice }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        func attach(to window: NSWindow?) {
            if self.window !== window {
                if let alert { self.window?.endSheet(alert.window, returnCode: .abort) }
                observers.forEach(NotificationCenter.default.removeObserver)
                observers = []
                self.window = window
                if let window {
                    for name in [NSWindow.didEndSheetNotification, NSWindow.didBecomeKeyNotification] {
                        observers.append(NotificationCenter.default.addObserver(forName: name,
                            object: window, queue: .main) { [weak self] _ in self?.schedule() })
                    }
                    observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                        object: window, queue: .main) { [weak self] _ in self?.attach(to: nil) })
                }
            }
            schedule()
        }

        func schedule() {
            guard !scheduled else { return }
            scheduled = true
            // SwiftUI's presentation bindings settle before checking AppKit's actual sheet.
            DispatchQueue.main.async { [weak self] in
                self?.scheduled = false
                self?.presentIfReady()
            }
        }

        private func presentIfReady() {
            guard enabled, alert == nil, let window, window.isVisible, window.attachedSheet == nil,
                  let claim = notice.beginPresentation() else { return }
            let shown = notice.entries
            let alert = NSAlert()
            alert.messageText = RemovedDeploymentNotice.title
            alert.informativeText = RemovedDeploymentNotice.message(for: shown)
            alert.addButton(withTitle: "OK")
            self.alert = alert
            alert.beginSheetModal(for: window) { [weak self, notice] response in
                if response == .alertFirstButtonReturn { notice.dismiss(shown) }
                notice.endPresentation(claim)
                self?.alert = nil
                self?.schedule()
            }
        }
    }
}
