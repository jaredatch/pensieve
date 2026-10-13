import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class SyncTokenViewTests: XCTestCase {
    func testTokenControlRemainsAvailableInConnectedSyncStates() async throws {
        for state in [SyncModel.SyncState.idle, .syncing, .synced(at: Date()),
                      .conflicted(["skills/example/SKILL.md"]), .error("token refused"), .branchless] {
            for saved in [false, true] { try await exerciseControl(state: state, saved: saved) }
        }
    }

    private func exerciseControl(state: SyncModel.SyncState, saved: Bool) async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        let paths = fixture.paths
        let probe = RenderedButtonTestSupport()
        if saved { try paths.makeCredentialStore().store(token: "saved", username: "kept", forHost: "fixture.test") }
        if state == .branchless {
            _ = try NativeTestWork.run { try paths.makeGitService().runOrThrow(
                ["update-ref", "-d", "refs/heads/main"], in: fixture.root) }
        }
        let sync = SyncModel(git: paths.makeGitService(), root: fixture.root, initialState: state)
        let runtime = try AppRuntime(syncModel: sync, scheduler: SyncScheduler(startAutomatically: false), paths: paths)
        await runtime.bootstrapTask.value
        let host = NSHostingView(rootView: AnyView(SyncSettingsView().environment(runtime)
            .buttonStyle(probe.style)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 438),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { probe.clear(); window.contentView = nil; window.close() }
        let button = try await probe.button(titled: saved ? "Replace…" : "Add…", in: host)
        XCTAssertEqual(sync.state, state)
        XCTAssertTrue(button.enabled, "Token repair must stay available in \(state)")
        let texts = RenderedViewTestSupport.values(in: host).compactMap { $0 as? Text }
            .flatMap(RenderedViewTestSupport.strings)
        XCTAssertTrue(texts.contains(saved ? "Token saved" : "No token saved"))
        if !saved { XCTAssertTrue(texts.contains("Sync over HTTPS needs an access token. Add one to keep syncing.")) }
        button.configuration.trigger()
        await TestWait.until(failureMessage: "Token control must open its sheet") { window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet)
        sheet.animationBehavior = .none
        let content = try XCTUnwrap(sheet.contentView)
        let titles = RenderedViewTestSupport.values(in: content).compactMap { $0 as? Text }
            .flatMap(RenderedViewTestSupport.strings)
        XCTAssertTrue(titles.contains(saved ? "Replace the access token" : "Add an access token"))
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53))
        XCTAssertTrue(content.performKeyEquivalent(with: escape) || sheet.performKeyEquivalent(with: escape))
        await TestWait.until(failureMessage: "Token sheet did not detach after Cancel") { window.attachedSheet == nil }
    }

}
