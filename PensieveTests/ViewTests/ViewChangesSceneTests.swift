import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class ViewChangesSceneTests: XCTestCase {
    func testRealCloseCancelsLoadingWorkerAndNeverPublishesItsLatePreview() async throws {
        let fixture = try UpdateReviewFixture()
        defer { try? fixture.cleanup() }
        let skill = try fixture.skill("closing")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let started = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let gate = TestWait.Gate(owner: self)
        let cancellation = UpdateReviewRecorder<Bool>()
        let model = ViewChangesViewModel(operations: fixture.operations(rows: [row], diff: { _, _, _, _ in
            started.signal()
            try gate.wait()
            cancellation.append(Task.isCancelled)
            completed.signal()
            return UpdateReviewFixture.preview()
        }))
        // The production lifecycle bridge observes AppKit's actual close, also on the macOS 14 fallback.
        let window = makeWindow(id: "closing")
        window.contentView = NSHostingView(rootView: ViewChangesView(model: model, library: fixture.library,
                                                                    onClose: { window.performClose(nil) })
            .modelContainer(fixture.container))
        window.orderFront(nil)
        defer { window.close() }
        model.open(skillID: skill.id, context: fixture.context)
        let didStart = await TestWait.forSemaphore(started)
        XCTAssertTrue(didStart)
        window.performClose(nil)
        await TestWait.until(failureMessage: "close lifecycle did not clear loading") { model.state == .idle }
        gate.open()
        let didFinish = await TestWait.forSemaphore(completed)
        XCTAssertTrue(didFinish)
        XCTAssertEqual(cancellation.values, [true])
        XCTAssertNil(model.selectedFile)
        XCTAssertNil(model.row)
        XCTAssertEqual(model.state, .idle)
    }

    private func makeWindow(id: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.isReleasedWhenClosed = false
        return window
    }

}
