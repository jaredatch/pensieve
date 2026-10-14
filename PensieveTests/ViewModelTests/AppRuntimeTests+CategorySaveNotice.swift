import AppKit
import SwiftData
import XCTest
@testable import Pensieve

extension AppRuntimeTests {
    func testCategoryRefusalNoticeAppearsFromEachMainWindowSectionAndDismisses() async throws {
        let h = try ManifestSaveFixture(unopenableLock: true)
        let runtime = try categoryNoticeRuntime(h)
        let window = hostMainWindow(runtime: runtime)
        addTeardownBlock { @MainActor in
            h.saves.categoryNotice = nil
            await TestWait.until(failureMessage: "The category alert did not detach at teardown") { window.attachedSheet == nil }
            window.contentView = nil
            window.close()
            h.cleanup()
        }
        await runtime.bootstrapTask.value
        await runtime.performLaunchWorkIfNeeded(context: h.context)
        runtime.syncModel.applyConfiguration(.success(.init(remoteURL: "https://example.invalid/pensieve.git",
                                                           hasLocalBranches: true)),
                                             order: runtime.syncModel.beginConfiguration())
        await TestWait.until(failureMessage: "The main window sidebar did not render") {
            window.contentView.map {
                PendingSaveTerminationTests.views($0).contains { ($0 as? NSOutlineView)?.accessibilityLabel() == "Sidebar" }
            } ?? false
        }
        let outline = try XCTUnwrap(window.contentView.flatMap {
            PendingSaveTerminationTests.views($0).compactMap { $0 as? NSOutlineView }
                .first { $0.accessibilityLabel() == "Sidebar" }
        })
        for row in 0..<outline.numberOfRows {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            await Task.yield()
            h.categories.rename(h.local, to: "Drafts", context: h.context)
            h.categories.rename(h.local, to: "Final", context: h.context)
            h.categories.rename(h.doomed, to: "Other", context: h.context)
            await h.saves.waitUntilIdle()
            XCTAssertEqual(try XCTUnwrap(h.saves.categoryNotice).messages.count, 3)
            await TestWait.until(failureMessage: "The category refusal alert did not appear in section row \(row)") {
                window.attachedSheet != nil
            }
            let sheet = try XCTUnwrap(window.attachedSheet)
            sheet.animationBehavior = .none
            try assertCategoryNotice(sheet)
            let buttons = PendingSaveTerminationTests.views(try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSButton }
            try XCTUnwrap(buttons.first { $0.title == "OK" }).performClick(nil)
            await TestWait.until(failureMessage: "Dismissing the category notice did not clear its state") {
                window.attachedSheet == nil && h.saves.categoryNotice == nil
            }
        }
        XCTAssertEqual(outline.numberOfRows, SidebarSection.allCases.count, "Exercise the main-window sections")
    }

    private func assertCategoryNotice(_ sheet: NSWindow) throws {
        let text = PendingSaveTerminationTests.views(try XCTUnwrap(sheet.contentView))
            .compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: "\n")
        XCTAssertTrue(text.contains("Category changes couldn't be saved"), text)
        XCTAssertTrue(text.contains("Local"), text)
        XCTAssertTrue(text.contains("ZDelete"), text)
        XCTAssertTrue(text.contains("undone"), text)
        XCTAssertTrue(text.contains(POSIXError(.EISDIR).localizedDescription), text)
    }

    private func categoryNoticeRuntime(_ h: ManifestSaveFixture) throws -> AppRuntime {
        let paths = AppRuntimePaths(storeRoot: h.root, appSupportDir: h.root + "/support")
        return try AppRuntime(container: h.context.container, platformVM: neutralPlatformVM(), library: h.library,
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
            defaults: isolatedDefaults("category-notice"),
            launchReconcile: { _, _ in LaunchReconcileOutcome(rebuild: RebuildResult(), migrationRan: false,
                                                            ingestedHeadStamp: "launch") },
            launchBackfill: { _ in }, hasRemoteConfigured: { false },
            postSyncConvergence: PostSyncConvergence(root: h.root, deployReconciler: NoopDeployReconciler(),
                contextFactory: { ModelContext(h.context.container) }, categoryReconciler: NoopLedgerReconciler(),
                intentReconciler: NoopLedgerReconciler(), auditLog: { _, _ in }),
            launchIngestLockPath: h.root + "/support/launch.lock", paths: paths, gitUsabilityProbe: { .usable })
    }
}
