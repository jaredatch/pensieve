import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class RemovedDeploymentAlertTests: XCTestCase {
    func testSavedNoticeWaitsForTheAutomaticEmptyLibraryImportSheet() async throws {
        let h = try RemoteRemovalFixture(persistent: true)
        defer { h.cleanup() }
        try prepare(h)
        try h.pull()
        try h.sync()
        try h.reopen()
        let runtime = try await makeRuntime(h)
        let window = host(runtime)
        defer { close(window, runtime: runtime) }
        await TestWait.until(failureMessage: "Empty launch must present its import wizard first") {
            guard let root = window.attachedSheet?.contentView else { return false }
            return RenderedViewTestSupport.values(in: root).compactMap { $0 as? Text }
                .flatMap(RenderedViewTestSupport.strings).contains("Skip")
        }
        let wizard = try XCTUnwrap(window.attachedSheet)
        wizard.animationBehavior = .none
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: wizard.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertTrue(wizard.performKeyEquivalent(with: escape))
        let notice = try await alert(window, after: wizard)
        assertText(notice, contains: ["alpha", "Website", "Codex"])
        try clickOK(notice)
        await waitForDismissal(window)
    }

    func testRealWindowShowsCleanupAndOKPreservesArrivalsDuringTheAlert() async throws {
        let h = try RemoteRemovalFixture(skills: ["alpha", "gamma"], agents: RemoteRemovalFixture.projectAgents)
        defer { h.cleanup() }
        try prepare(h)
        let runtime = try await makeRuntime(h)
        let window = host(runtime)
        defer { close(window, runtime: runtime) }
        try h.pull()
        try h.sync()
        let first = try await alert(window)
        assertText(first, contains: ["alpha", "Website (" + h.root + "/Website)", "Claude Code", "Codex", "Cursor", "Grok"])
        try h.pull(slug: "gamma")
        try h.sync()
        try clickOK(first)
        let second = try await alert(window, after: first)
        assertText(second, contains: ["gamma", "Website", "Grok"])
        XCTAssertEqual(Set(runtime.platformVM.removedDeploymentNotice.entries.map(\.slug)), ["gamma"])
        try clickOK(second)
        await waitForDismissal(window)
        XCTAssertTrue(runtime.platformVM.removedDeploymentNotice.entries.isEmpty)
    }

    func testWindowOpenedLaterAndSavedNoticeAtLaunchListAllPendingRemovals() async throws {
        for restart in [false, true] {
            let h = try RemoteRemovalFixture(skills: ["alpha", "gamma", "keeper"], persistent: true,
                                             agents: RemoteRemovalFixture.projectAgents)
            defer { h.cleanup() }
            try prepare(h)
            try h.pull()
            try h.sync()
            try h.pull(slug: "gamma")
            try h.sync()
            if restart { try h.reopen(); try h.launch() }
            let runtime = try await makeRuntime(h)
            let window = host(runtime)
            defer { close(window, runtime: runtime) }
            let sheet = try await alert(window)
            assertText(sheet, contains: ["alpha", "gamma", "Website (" + h.root + "/Website)",
                                        "Claude Code", "Codex", "Cursor", "Grok"])
            try clickOK(sheet)
            await waitForDismissal(window)
            XCTAssertTrue(runtime.platformVM.removedDeploymentNotice.entries.isEmpty)
        }
    }

    func testNoticeWaitsForExistingWindowAlertAndSheet() async throws {
        for sheetFirst in [false, true] {
            let h = try RemoteRemovalFixture(skills: ["alpha", "gamma"])
            defer { h.cleanup() }
            try prepare(h)
            let runtime = try await makeRuntime(h)
            let window = host(runtime)
            defer { close(window, runtime: runtime) }
            if sheetFirst { runtime.library.showCreateSheet = true } else {
                runtime.library.deletionNotice = .warning("Existing warning")
            }
            await TestWait.until(failureMessage: "The existing presentation must attach first") {
                window.attachedSheet != nil
            }
            let existing = try XCTUnwrap(window.attachedSheet)
            existing.animationBehavior = .none
            try h.pull()
            try h.sync()
            XCTAssertTrue(window.attachedSheet === existing)
            XCTAssertEqual(runtime.platformVM.removedDeploymentNotice.entries.count, 3)
            if sheetFirst { runtime.library.showCreateSheet = false } else { try clickOK(existing) }
            let notice = try await alert(window, after: existing)
            assertText(notice, contains: ["alpha", "Website", "Codex"])
            try clickOK(notice)
            await waitForDismissal(window)
        }
    }

    private func prepare(_ h: RemoteRemovalFixture) throws {
        let project = try h.project("Website", keyed: false)
        try h.deployBefore()
        for slug in try h.store.listSkills() {
            try h.direct(project: project, agents: h.installedAgents, slug: slug)
        }
    }

    private func makeRuntime(_ h: RemoteRemovalFixture) async throws -> AppRuntime {
        let defaults = try h.paths.makeDefaults()
        defaults.set(false, forKey: AppRuntime.backgroundSyncEnabledKey)
        let runtime = try AppRuntime(container: h.context.container, platformVM: h.platform, defaults: defaults,
                                     postSyncConvergence: h.convergence, paths: h.paths)
        await runtime.bootstrapTask.value
        _ = await runtime.performLaunchWorkIfNeeded(context: h.context)
        return runtime
    }

    private func host(_ runtime: AppRuntime) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 850),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = NSHostingView(rootView: PensieveApp.makeContentView(runtime: runtime)
            .environment(runtime).modelContainer(runtime.container))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func close(_ window: NSWindow, runtime: AppRuntime) {
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort) }
        window.close()
        window.contentView = nil
        runtime.library.stopWatching()
        runtime.commandServer?.stop()
    }

    private func alert(_ window: NSWindow, after previous: NSWindow? = nil) async throws -> NSWindow {
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                            failureMessage: "The removed-deployment alert must attach to the production window") {
            guard let sheet = window.attachedSheet, sheet !== previous else { return false }
            return self.labels(sheet).contains("Pensieve removed deployments from this Mac")
        }
        XCTAssertNotNil(window.attachedSheet, "Missing alert must fail before unwrapping")
        let sheet = try XCTUnwrap(window.attachedSheet)
        sheet.animationBehavior = .none
        return sheet
    }

    private func assertText(_ sheet: NSWindow, contains words: [String]) {
        let text = labels(sheet).joined(separator: "\n")
        for word in words { XCTAssertTrue(text.contains(word), text) }
        XCTAssertTrue(text.contains("Deploy it again if you still want it there."), text)
    }

    private func labels(_ window: NSWindow) -> [String] {
        window.contentView.map { views($0).compactMap { ($0 as? NSTextField)?.stringValue } } ?? []
    }

    private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }

    private func clickOK(_ sheet: NSWindow) throws {
        let root = try XCTUnwrap(sheet.contentView)
        let button = try XCTUnwrap(views(root).compactMap { $0 as? NSButton }.first { $0.title == "OK" })
        button.performClick(nil)
    }

    private func waitForDismissal(_ window: NSWindow) async {
        await TestWait.until(failureMessage: "OK must detach the alert") { window.attachedSheet == nil }
    }
}
