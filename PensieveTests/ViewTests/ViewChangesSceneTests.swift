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
        let model = ViewChangesViewModel(library: fixture.library,
            operations: fixture.operations(rows: [row], diff: { _, _ in
            started.signal()
            try gate.wait()
            cancellation.append(Task.isCancelled)
            completed.signal()
            return UpdateReviewFixture.preview()
        }))
        // The production lifecycle bridge observes AppKit's actual close, also on the macOS 14 fallback.
        let window = makeWindow(id: "closing")
        window.contentView = NSHostingView(rootView: ViewChangesView(model: model, library: fixture.library,
                                                                    onUpdate: {})
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

    func testSceneChromeAndMinimumSizeFitThe1040By660Frame() async throws {
        if #available(macOS 26, *) {
            let fixture = try UpdateReviewFixture()
            defer { try? fixture.cleanup() }
            let skill = try fixture.skill("geometry")
            let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
            let model = ViewChangesViewModel(library: fixture.library, operations: fixture.operations(rows: [row]))
            model.open(skillID: skill.id, context: fixture.context)
            await TestWait.until(failureMessage: "geometry preview did not load") { model.state != .loading }
            let representation = NSHostingSceneRepresentation {
                ViewChangesScene(model: model, library: fixture.library,
                                 updates: fixture.sheet(rows: [row]), container: fixture.container)
            }
            NSApp.addSceneRepresentation(representation)
            representation.environment.openWindow(id: WindowPolicy.changesWindowID)
            await TestWait.until(failureMessage: "View Changes scene did not open") {
                NSApp.windows.contains { $0.isVisible && $0.accessibilityIdentifier() == WindowPolicy.changesWindowID }
            }
            let window = try XCTUnwrap(NSApp.windows.first {
                $0.isVisible && $0.accessibilityIdentifier() == WindowPolicy.changesWindowID
            })
            defer { window.close() }
            let main = makeWindow(id: "main-AppWindow-geometry")
            defer { main.close() }
            main.orderFront(nil)
            XCTAssertTrue(WindowPolicy.mainWindow(among: [window, main]) === main)
            XCTAssertTrue(WindowPolicy.extraMainWindows(among: [main, window]).isEmpty)
            XCTAssertEqual(window.frame.width, 1040, accuracy: 1)
            XCTAssertLessThanOrEqual(window.minSize.height, 660, "The window must resize to the frame's height")
            XCTAssertEqual(window.frame.height, 660, accuracy: 1, "Default size includes all window chrome")
            XCTAssertEqual(window.titlebarSeparatorStyle, .none, "Full-height chrome has no title-bar strip")
            XCTAssertEqual(window.title, "Changes to Geometry", "Use the native plain-text window title")
            XCTAssertEqual(window.subtitle, "example/repository · 1111111 → 2222222")
            try assertVisibleHeading(in: window)
            let update = try XCTUnwrap(window.toolbar?.items.first {
                $0.itemIdentifier.rawValue.contains("changes-update")
            }?.view)
            XCTAssertGreaterThanOrEqual(update.convert(update.bounds, to: nil).maxX, window.frame.width - 30,
                                        "Review actions belong at the toolbar's trailing edge")
            let github = try XCTUnwrap(window.toolbar?.items.first {
                $0.itemIdentifier.rawValue.contains("changes-github")
            }?.view)
            XCTAssertLessThan(github.convert(github.bounds, to: nil).maxX, update.convert(update.bounds, to: nil).minX,
                              "View on GitHub precedes Update at the trailing edge")
            let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
            XCTAssertEqual(update.convert(update.bounds, to: nil).midY,
                           close.convert(close.bounds, to: nil).midY, accuracy: 8,
                           "Toolbar and traffic lights share the same row")
        }
    }

    func makeWindow(id: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.isReleasedWhenClosed = false
        return window
    }

}
