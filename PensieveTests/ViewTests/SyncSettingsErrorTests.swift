import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class SyncSettingsErrorTests: XCTestCase {
    func testSettingsSyncShowsTheOutstandingErrorOnceAndOnlyWhileItStands() async throws {
        let reason = "fixture.test didn’t accept the access token. Replace it in Settings › Sync."
        let h = try await SyncFailureViewFixture(reason: reason)
        defer { h.cleanup() }
        let window = SyncFailureViewHost.mount(AnyView(SyncSettingsView().environment(h.runtime)))
        defer { SyncFailureViewHost.close(window) }
        let host = try XCTUnwrap(window.contentView)
        await TestWait.until(failureMessage: "Settings never showed the outstanding error") {
            SyncFailureViewHost.texts(in: host).contains(reason)
        }
        XCTAssertEqual(SyncFailureViewHost.texts(in: host).filter { $0 == reason }.count, 1)
        XCTAssertTrue(SyncFailureViewHost.texts(in: host).contains("Sync failed"))
        for result in [SyncCycleResult.locked, .synced(pushed: false, warnings: [], completedAt: Date()),
                       .conflicted(["skills/example/SKILL.md"]), .branchless] {
            h.sync.apply(result)
            await assertAbsent(reason, in: host)
        }
        h.sync.apply(.failed(reason))
        h.sync.installSyncRequest { await self.assertAbsent(reason, in: host) }
        await h.sync.syncNowAndReport()
        h.sync.apply(.failed(reason))
        await TestWait.until(failureMessage: "Error must return before the success") {
            SyncFailureViewHost.texts(in: host).contains(reason)
        }
        h.sync.apply(.synced(pushed: false, warnings: [], completedAt: Date()))
        await assertAbsent(reason, in: host)
        try h.disk.files.deleteFile(at: h.disk.root + "/.git/HEAD")
        await h.runtime.refreshGitUsability()
        let configurationError = try XCTUnwrap(h.sync.configurationError)
        await TestWait.until(failureMessage: "Repository error did not render") {
            SyncFailureViewHost.texts(in: host).contains(configurationError)
        }
        XCTAssertEqual(SyncFailureViewHost.texts(in: host).filter { $0 == configurationError }.count, 1)
        XCTAssertFalse(SyncFailureViewHost.texts(in: host).contains("Sync failed"))
    }

    private func assertAbsent(_ reason: String, in host: NSView) async {
        await TestWait.until(failureMessage: "Settings retained a cleared error") {
            let texts = SyncFailureViewHost.texts(in: host)
            return !texts.contains(reason) && !texts.contains("Sync failed")
        }
    }
}
