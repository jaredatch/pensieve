import XCTest
@testable import Pensieve

@MainActor
final class PensieveAppInstallPathsTests: XCTestCase {
    func testInstallSheetUsesRuntimePathsAndMemoryCredentials() throws {
        let paths = try AppRuntimePaths.temporary(named: "PensieveAppInstallPathsTests")
        let temporaryRoot = (paths.storeRoot as NSString).deletingLastPathComponent
        defer { try? FileService().deleteDirectory(at: temporaryRoot) }
        let runtime = try AppRuntime(
            paths: paths,
            gitUsabilityProbe: { .usable }
        )
        let view = PensieveApp.makeContentView(runtime: runtime)
        let service = try XCTUnwrap(view.installVM.service as? SkillInstallService)

        XCTAssertEqual(service.storeRoot, paths.storeRoot)
        XCTAssertEqual(service.scratchRoot, paths.appSupportDir + "/skill-install-scratch")
        XCTAssertEqual(service.lockPath, paths.syncLockPath)
        XCTAssertTrue(service.credentialStore is InMemoryCredentialStore)
    }
    func testDockReopenOpensMainWhenOnlyViewChangesIsVisible() throws {
        let paths = try AppRuntimePaths.temporary(named: "DockReopen")
        defer { try? FileService().deleteDirectory(at: (paths.storeRoot as NSString).deletingLastPathComponent) }
        let runtime = try AppRuntime(paths: paths, gitUsabilityProbe: { .usable })
        let delegate = try XCTUnwrap(PensieveAppDelegate.shared)
        let previousRuntime = delegate.runtime
        delegate.runtime = runtime
        defer { delegate.runtime = previousRuntime }
        let previousMains = NSApp.windows.filter { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main-") == true }
        previousMains.forEach { $0.orderOut(nil) }
        defer { previousMains.forEach { $0.orderFront(nil) } }
        let changes = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        changes.isReleasedWhenClosed = false
        changes.identifier = NSUserInterfaceItemIdentifier("view-changes-AppWindow-dock")
        changes.orderFront(nil)
        var opened = 0
        var main: NSWindow?
        runtime.registerOpenMainWindowAction {
            opened += 1
            let window = NSWindow(contentRect: changes.frame, styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier("main-AppWindow-dock")
            window.orderFront(nil)
            main = window
        }
        defer { main?.close(); changes.close() }
        XCTAssertNil(WindowPolicy.mainWindow(among: NSApp.windows))
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        XCTAssertEqual(opened, 1, "Dock reopen must restore main even when the review window is visible")
        XCTAssertTrue(changes.isVisible)
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        XCTAssertEqual(opened, 1, "A second Dock click must reuse the existing main window")
    }

}
