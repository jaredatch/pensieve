import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class SyncFailureFooterHostTests: XCTestCase {
    func testClickingTheFailedSyncLineOpensItsReasonAndSyncNowRetries() async throws {
        let reason = "git push failed: fixture reason"
        let h = try await SyncFailureViewFixture(reason: reason)
        defer { h.cleanup() }
        h.mountFooter()
        XCTAssertTrue(h.footer?.childWindows?.isEmpty != false)
        try await h.clickFooter()
        let popover = try await h.popover(), content = try XCTUnwrap(popover.contentView)
        let texts = SyncFailureViewHost.texts(in: content)
        XCTAssertTrue(texts.contains("Sync failed"))
        XCTAssertTrue(texts.contains(reason))
        XCTAssertEqual(h.retries, 0)
        XCTAssertEqual(h.sync.state, .error(reason))
        try await h.press("Sync Now")
        await TestWait.until(failureMessage: "Retry must reach the model once") { h.retries == 1 }
        await h.assertClosed()
        XCTAssertEqual(h.retries, 1)
    }

    func testAnOpenReasonFollowsTheErrorAndClosesWhenItClears() async throws {
        let h = try await SyncFailureViewFixture(reason: "Reason A")
        defer { h.cleanup() }
        h.mountFooter()
        try await h.clickFooter()
        let popover = try await h.popover(), content = try XCTUnwrap(popover.contentView)
        XCTAssertTrue(SyncFailureViewHost.texts(in: content).contains("Reason A"))
        h.sync.apply(.failed("Reason B"))
        await TestWait.until(failureMessage: "Open reason did not follow the current error") {
            let texts = SyncFailureViewHost.texts(in: content)
            return texts.contains("Reason B") && !texts.contains("Reason A")
        }
        XCTAssertEqual(h.footer?.childWindows?.count, 1)
        h.sync.installSyncRequest {
            XCTAssertEqual(h.sync.state, .syncing)
            await h.assertClosed()
            h.sync.apply(.failed("Retry failed"))
        }
        await h.sync.syncScheduledAndReport()
        await h.assertClosed()
        let footer = try XCTUnwrap(h.footer?.contentView)
        XCTAssertTrue(SyncFailureViewHost.texts(in: footer).contains("Sync failed"))
        for result in [SyncCycleResult.synced(pushed: false, warnings: [], completedAt: Date()),
                       .conflicted(["skills/example/SKILL.md"])] {
            try await h.clickFooter()
            _ = try await h.popover()
            h.sync.apply(result)
            await h.assertClosed()
            h.sync.apply(.failed("Next failure"))
            await h.assertClosed()
        }
        h.sync.apply(.failed("Before damage"))
        try await h.clickFooter()
        _ = try await h.popover()
        // Finish the mounted footer's state-triggered read before reporting fresh damage.
        await h.saves.refreshAndRetry()
        h.saves.libraryDamaged = true
        await h.assertClosed()
        try await h.clickFooter()
        await TestWait.until(failureMessage: "Repair line did not request repair") { h.saves.showsRepairConfirmation }
        await h.assertClosed()
        h.saves.cancelRepair()
        h.saves.libraryDamaged = false
        h.sync.apply(.failed("Before disconnect"))
        await h.assertClosed()
        try await h.clickFooter()
        _ = try await h.popover()
        h.sync.applyConfiguration(.success(.init(remoteURL: nil, hasLocalBranches: true)), order: h.sync.beginConfiguration())
        await h.assertClosed()
        XCTAssertFalse(SyncFailureViewHost.texts(in: footer).contains("Sync failed"))
    }

    func testOpenSyncSettingsLandsOnTheSyncPageFromAnotherTab() async throws {
        let reason = try SyncFailureViewFixture.advice(credential: .httpsToken(
            username: "kept", token: "expired", host: "fixture.test"))
        for tab in [AppRuntime.SettingsTab.general, .github] {
            let h = try await SyncFailureViewFixture(reason: reason)
            defer { h.cleanup() }
            h.runtime.selectedSettingsTab = tab
            let settings = SyncFailureViewHost.mount(AnyView(SettingsView().environment(h.runtime)
                .modelContainer(h.runtime.container)))
            defer { SyncFailureViewHost.close(settings) }
            let host = try XCTUnwrap(settings.contentView)
            let expected = tab == .general ? "Skills Directory" : "Private repositories"
            await TestWait.until(failureMessage: "Settings did not start on the other page") {
                SyncFailureViewHost.texts(in: host).contains(expected)
            }
            XCTAssertFalse(SyncFailureViewHost.texts(in: host).contains("Repository"))
            h.mountFooter()
            try await h.clickFooter()
            _ = try await h.popover()
            try await h.press("Open Sync Settings…")
            await TestWait.until(failureMessage: "Open Sync Settings did not arrive on Sync") {
                let texts = SyncFailureViewHost.texts(in: host)
                return texts.contains("Repository") && texts.contains(reason) && texts.contains("Sync failed")
            }
            XCTAssertEqual(h.settingsOpens, 1)
            await h.assertClosed()
        }
    }
}
