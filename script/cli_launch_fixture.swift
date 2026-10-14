// A throwaway app for the black-box CLI launcher tests. It has no store or Pensieve bundle identity.
import AppKit
import CoreGraphics
import Foundation

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var reopens = 0
    func report() {
        let state: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
            "path": Bundle.main.bundlePath, "arguments": CommandLine.arguments,
            "active": NSApp.isActive, "windows": NSApp.windows.filter(\.isVisible).count, "reopens": reopens]
        let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(Bundle.main.bundleURL.lastPathComponent + ".json")
        try! JSONSerialization.data(withJSONObject: state).write(to: url, options: .atomic)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !CommandLine.arguments.contains("--background") {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                styleMask: .titled, backing: .buffered, defer: false)
            window?.makeKeyAndOrderFront(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.report() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { NSApp.terminate(nil) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        reopens += 1
        report()
        return false
    }
}

if CommandLine.arguments.contains("--frontmost") {
    print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)
} else if CommandLine.arguments.count > 2 && CommandLine.arguments[1] == "--reopen" {
    let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
        eventID: AEEventID(kAEReopenApplication),
        targetDescriptor: NSAppleEventDescriptor(processIdentifier: Int32(CommandLine.arguments[2])!),
        returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    _ = try event.sendEvent(options: [.waitForReply], timeout: 5)
} else if CommandLine.arguments.count > 2 && CommandLine.arguments[1] == "--windows" {
    let pid = Int32(CommandLine.arguments[2])!
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    print(windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid
        && ($0[kCGWindowLayer as String] as? Int) == 0 }.count)
} else {
    let app = NSApplication.shared
    let delegate = FixtureDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
