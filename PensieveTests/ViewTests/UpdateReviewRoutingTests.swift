import AppKit
import XCTest
@testable import Pensieve

@MainActor
final class UpdateReviewRoutingTests: XCTestCase {
    func testBannerActionsRouteItsSkillAndUpdateSelectsOnlyThatSkill() async throws {
        let fixture = try UpdateReviewFixture()
        defer { try? fixture.cleanup() }
        let first = try fixture.skill("first")
        let second = try fixture.skill("second")
        let rows = try [first, second].map { try UpdatesViewModel.makeRow(skill: $0, driftedLocally: true) }
        let (sheet, preview) = fixture.review(rows: rows)
        var opened: [String] = []
        let routing = UpdateReviewRouting(preview: preview, updates: sheet, library: fixture.library,
                                         context: fixture.context, windows: { [] }, openWindow: { opened.append($0) })
        let banner = routing.banner(for: first)
        banner.onViewChanges()
        await loaded(preview)
        XCTAssertEqual(preview.row?.id, first.id)
        XCTAssertEqual(opened, [WindowPolicy.changesWindowID])
        XCTAssertFalse(sheet.isPresented)

        banner.onUpdate()
        XCTAssertTrue(sheet.isPresented)
        sheet.load(context: fixture.context)
        await TestWait.until(failureMessage: "requested sheet selection did not load") { !sheet.isLoading }
        XCTAssertEqual(sheet.selectedSkillIDs, [first.id])
        XCTAssertTrue(sheet.rows.first { $0.id == first.id }?.driftedLocally == true)
        await sheet.applySelectedAndReport(context: fixture.context)
        XCTAssertEqual(sheet.status(for: try XCTUnwrap(rows.first)), .confirmationRequired)
        XCTAssertEqual(sheet.status(for: try XCTUnwrap(rows.last)), .idle)
    }

    func testSheetRowRoutesItsSkillAndResetLeavesPreviewAndFileSelectionAlone() async throws {
        let fixture = try UpdateReviewFixture()
        defer { try? fixture.cleanup() }
        let first = try fixture.skill("first")
        let second = try fixture.skill("second")
        let rows = try [first, second].map { try UpdatesViewModel.makeRow(skill: $0, driftedLocally: false) }
        let (sheet, preview) = fixture.review(rows: rows)
        let routing = UpdateReviewRouting(preview: preview, updates: sheet, library: fixture.library,
                                         context: fixture.context, windows: { [] }, openWindow: { _ in })
        sheet.present(selecting: first.id, library: fixture.library)
        routing.sheet.onViewChanges(try XCTUnwrap(rows.last))
        await loaded(preview)
        XCTAssertEqual(preview.row?.id, second.id)
        XCTAssertTrue(sheet.isPresented)
        preview.selectFile(path: "scripts/setup.sh")
        let selected = preview.selectedFile
        sheet.isPresented = false
        sheet.reset()
        XCTAssertEqual(preview.selectedFile, selected)
        XCTAssertEqual(preview.selectedFilePath, "scripts/setup.sh")
        XCTAssertEqual(preview.row?.id, second.id)
    }

    func testPresenterReusesWindowWhileSwitchingCancelsAndDropsLatePreview() async throws {
        let fixture = try UpdateReviewFixture()
        defer { try? fixture.cleanup() }
        let first = try fixture.skill("first")
        let second = try fixture.skill("second")
        let rows = try [first, second].map { try UpdatesViewModel.makeRow(skill: $0, driftedLocally: false) }
        let gate = TestWait.Gate(owner: self)
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let cancelled = UpdateReviewRecorder<Bool>()
        let (sheet, preview) = fixture.review(rows: rows, diff: { request, _ in
            if request.id == first.id {
                started.signal()
                try gate.wait()
                cancelled.append(Task.isCancelled)
                finished.signal()
                return try PinnedSkillDiff.build(comparison: FileTreeComparison(changes: [
                    FileTreeChange(path: "late-first", kind: .modified, content: .binary)
                ], unreadFileCount: 0, bytesRead: 0))
            }
            return UpdateReviewFixture.preview()
        })
        let window = makeWindow()
        defer { window.close() }
        var opened: [String] = []
        let routing = UpdateReviewRouting(preview: preview, updates: sheet, library: fixture.library,
                                         context: fixture.context, windows: { [window] }, openWindow: {
            opened.append($0)
            window.orderFront(nil)
        })
        routing.banner(for: first).onViewChanges()
        let didStart = await TestWait.forSemaphore(started)
        XCTAssertTrue(didStart)
        routing.sheet.onViewChanges(try XCTUnwrap(rows.last))
        await loaded(preview)
        XCTAssertEqual(opened, [WindowPolicy.changesWindowID], "The existing window must be reused")
        XCTAssertEqual(preview.row?.id, second.id)
        let secondState = preview.state
        gate.open()
        let didFinish = await TestWait.forSemaphore(finished)
        XCTAssertTrue(didFinish)
        await Task.yield()
        XCTAssertEqual(cancelled.values, [true])
        XCTAssertEqual(preview.state, secondState)
        XCTAssertFalse(preview.files.contains { $0.path == "late-first" })
    }

    private func loaded(_ preview: ViewChangesViewModel) async {
        await TestWait.until(failureMessage: "routed preview did not load") { preview.state != .loading }
        XCTAssertNotNil(preview.selectedFile)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        WindowPolicy.configureChangesWindow(window)
        return window
    }
}
