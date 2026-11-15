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
            window.animationBehavior = .none
            defer { closeSceneWindow(window) }
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

    private func closeSceneWindow(_ window: NSWindow) {
        window.close()
        window.contentView = nil
    }

    func makeWindow(id: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        return window
    }

}

@MainActor
final class PolishReview {
    let fixture: UpdateReviewFixture
    let skills: [Skill]
    let model: ViewChangesViewModel
    let window: NSWindow
    var root: NSView { window.contentView! }
    var operationGate: TestWait.Gate? {
        get { gate.value }
        set { gate.value = newValue }
    }
    private let gate: PolishGate

    init(previews: [PinnedSkillDiff]) async throws {
        let fixture = try UpdateReviewFixture()
        self.fixture = fixture
        skills = try (0...previews.count).map { try fixture.skill("polish-\($0)") }
        let rows = try skills.map { try UpdatesViewModel.makeRow(skill: $0, driftedLocally: false) }
        let gate = PolishGate()
        self.gate = gate
        let model = ViewChangesViewModel(library: fixture.library,
            operations: fixture.operations(rows: rows, diff: { row, _ in
                try gate.value?.wait()
                guard let index = rows.firstIndex(where: { $0.id == row.id }), previews.indices.contains(index) else {
                    throw CocoaError(.fileReadUnknown)
                }
                return previews[index]
            }))
        self.model = model
        let representation = NSHostingSceneRepresentation {
            ViewChangesScene(model: model, library: fixture.library,
                             updates: fixture.sheet(rows: rows), container: fixture.container)
        }
        NSApp.addSceneRepresentation(representation)
        representation.environment.openWindow(id: WindowPolicy.changesWindowID)
        await TestWait.until(failureMessage: "The production View Changes scene did not open") {
            NSApp.windows.contains {
                $0.isVisible && $0.accessibilityIdentifier() == WindowPolicy.changesWindowID
            }
        }
        window = try XCTUnwrap(NSApp.windows.first {
            $0.isVisible && $0.accessibilityIdentifier() == WindowPolicy.changesWindowID
        })
        window.animationBehavior = .none
    }

    func load(_ index: Int) async throws {
        model.open(skillID: skills[index].id, context: fixture.context)
        await TestWait.until(failureMessage: "Polish preview did not finish loading") { self.model.state != .loading }
        await settle(model.files.first?.path ?? (model.files.isEmpty && index == skills.count - 1
            ? "Couldn't Load Changes" : "No File Changes"))
    }

    func settle(_ string: String) async {
        await TestWait.until(failureMessage: "Missing rendered \(string)") {
            RenderedViewTestSupport.values(in: self.root).compactMap { $0 as? Text }
                .flatMap(RenderedViewTestSupport.strings).contains(string)
        }
        let clock = ContinuousClock()
        var previous: [CGRect?] = []
        var stableSince = clock.now
        await TestWait.until(failureMessage: "The live layout did not settle") {
            let frames = RenderedViewTestSupport.layoutValues(in: self.root).map(\.frame)
            if frames != previous { previous = frames; stableSince = clock.now }
            return stableSince.duration(to: clock.now) >= .milliseconds(300)
        }
    }
}

private final class PolishGate: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TestWait.Gate?
    var value: TestWait.Gate? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

@MainActor
func polishSidebarButtonFrame(in window: NSWindow) throws -> CGRect {
    let host = try XCTUnwrap(window.toolbar?.items.first {
        $0.itemIdentifier.rawValue.contains("navigationSplitView.toggleSidebar")
    }?.view)
    let values = RenderedViewTestSupport.layoutValues(in: host)
    let button = try XCTUnwrap(values.first {
        String(reflecting: type(of: $0.value)).hasPrefix("SwiftUI.Button<")
    }?.frame, "Missing live sidebar toolbar button")
    return window.convertToScreen(host.convert(button, to: nil))
}
