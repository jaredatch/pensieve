import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class SyncFailurePopoverTests: XCTestCase {
    func testPopoverShowsTheReasonAndOffersSyncSettingsOnlyWhenTheAdviceNamesThem() async throws {
        let reasons = [
            try SyncFailureViewFixture.advice(credential: .httpsToken(username: "kept", token: "expired", host: "fixture.test")),
            try SyncFailureViewFixture.advice(credential: nil),
            try SyncFailureViewFixture.advice(credential: .sshAgent, ssh: true),
            "git push failed: " + String(repeating: "x", count: 600)
        ]
        for (index, reason) in reasons.enumerated() {
            let probe = RenderedButtonTestSupport()
            var syncs = 0, settings = 0
            let window = SyncFailureViewHost.mount(AnyView(SyncFailurePopover(reason: reason, canSyncNow: true,
                onSync: { syncs += 1 }, onOpenSyncSettings: { settings += 1 }).buttonStyle(probe.style)))
            defer { probe.clear(); SyncFailureViewHost.close(window) }
            let host = try XCTUnwrap(window.contentView)
            let button = try await probe.button(titled: "Sync Now", in: host)
            let texts = SyncFailureViewHost.texts(in: host)
            XCTAssertTrue(texts.contains("Sync failed"))
            XCTAssertTrue(texts.contains(reason), "The complete reason must render even when it scrolls")
            XCTAssertTrue(button.enabled)
            button.configuration.trigger()
            XCTAssertEqual(syncs, 1)
            XCTAssertEqual(texts.contains("Open Sync Settings…"), index < 2)
            if index < 2 {
                let settingsButton = try await probe.button(titled: "Open Sync Settings…", in: host)
                settingsButton.configuration.trigger()
                XCTAssertEqual(settings, 1)
            } else { XCTAssertEqual(settings, 0) }
        }
        let probe = RenderedButtonTestSupport()
        let model = SyncModel(git: TestPaths.git, root: TestPaths.storeRoot, initialState: .unconfigured)
        XCTAssertFalse(model.canSyncNow)
        let window = SyncFailureViewHost.mount(AnyView(SyncFailurePopover(reason: "boom", canSyncNow: model.canSyncNow,
            onSync: { XCTFail("Disabled retry fired") }, onOpenSyncSettings: {}).buttonStyle(probe.style)))
        defer { probe.clear(); SyncFailureViewHost.close(window) }
        let button = try await probe.button(titled: "Sync Now", in: XCTUnwrap(window.contentView))
        XCTAssertFalse(button.enabled)
    }
}
