import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

extension SkillHistoryLayoutTests {
    func testUnlabeledButtonCaptionCanBecomeReadyAfterFirstPoll() async {
        let fixture = captionHost()
        let button = fixture.button
        defer { fixture.window.close() }

        let pressed = await HistoryAccessibility.pressButton(titled: "Ready", in: fixture.root)
        XCTAssertTrue(pressed,
                      "A later poll must locate the newly rendered caption; title=\(button.title), reads=\(button.captures)")
        XCTAssertGreaterThan(button.captures, 1, "A stale OCR miss must be read again")
        XCTAssertEqual(button.presses, 1, "A caption becoming ready must still cause only one press")
    }

    func testAccessibleButtonNamesDecideLookupWithoutOCR() {
        for exposeLabel in [false, true] {
            let fixture = captionHost()
            let button = fixture.button
            defer { fixture.window.close() }
            button.title = "Ready"
            button.setAccessibilityRole(.button)
            if exposeLabel { button.exposedLabel = "Accessible" } else { button.exposedTitle = "Accessible" }

            XCTAssertFalse(HistoryAccessibility.pressButtonIfFound(titled: "Ready", in: fixture.root),
                           "A nonmatching accessibility name must prevent an OCR-based press")
            XCTAssertEqual(button.captures, 0, "An accessibility name must decide a miss without capturing pixels")
            let pressed = HistoryAccessibility.pressButtonIfFound(titled: "Accessible", in: fixture.root)
            XCTAssertTrue(pressed, "The matching accessibility name must still locate and press the control")
            XCTAssertEqual(button.captures, 0, "An accessibility name must decide a match without capturing pixels")
            XCTAssertEqual(button.presses, 1, "Only the matching accessibility name may press the control")
        }
    }

    func testEmptyButtonTitleNeverPressesAnEmptyLabeledControl() async {
        let root = NSView()
        let button = FalseReturningHistoryButton()
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel("")
        root.setAccessibilityChildren([button])
        let asyncPressed = await HistoryAccessibility.pressButton(titled: "", in: root)
        XCTAssertFalse(asyncPressed, "An empty title must be rejected before an async press")
        XCTAssertFalse(HistoryAccessibility.pressButtonIfFound(titled: "", in: root),
                       "An empty title must be rejected before an immediate press")
        XCTAssertEqual(button.presses, 0, "An empty target must never press an empty-labeled control")
    }

    func testLabeledButtonReportsPressWhenAccessibilityReturnsFalse() async {
        let root = NSView()
        let button = FalseReturningHistoryButton()
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel("Test press")
        root.setAccessibilityChildren([button])
        let pressed = await HistoryAccessibility.pressButton(titled: "Test press", in: root)
        XCTAssertTrue(pressed,
                      "Finding and pressing a labeled control must not depend on its AX return value")
        XCTAssertEqual(button.presses, 1, "A located button must receive exactly one press")
    }

    func testShowOlderCommitsButtonRevealsHeldRows() async throws {
        let host = makeHost(try countFixture(), height: 1800)
        defer { host.window.close() }
        host.window.styleMask = [.titled, .closable]
        NSApp.activate(ignoringOtherApps: true)
        host.window.makeKeyAndOrderFront(nil)

        let initial = try await settledDots(
            in: host.view, expecting: 10, timeout: TestWait.firstRenderTimeoutSeconds
        )
        XCTAssertEqual(initial.count, 10, "the installed view draws ten initial rows")
        let pressed = await HistoryAccessibility.pressButton(titled: "Show older commits", in: host.view)
        XCTAssertTrue(pressed, "The rendered Show older commits button must be found and pressed")
        let revealed = try await settledDots(in: host.view, expecting: 12)
        XCTAssertEqual(revealed.count, 12, "pressing Show older commits renders all twelve held rows")
    }
}

private final class FalseReturningHistoryButton: NSAccessibilityElement {
    private(set) var presses = 0

    override func accessibilityPerformPress() -> Bool {
        presses += 1
        return false
    }
}

private final class ChangingHistoryCaptionButton: NSButton {
    private(set) var captures = 0
    private(set) var presses = 0
    var exposedTitle: String?
    var exposedLabel: String?

    override func accessibilityTitle() -> String? { exposedTitle }
    override func accessibilityLabel() -> String? { exposedLabel }
    override func accessibilityPerformPress() -> Bool { presses += 1; return false }

    override func draw(_ dirtyRect: NSRect) {
        // Render real glyphs in a plain button: native bezel compositing can omit its caption from cacheDisplay.
        NSColor.white.setFill()
        dirtyRect.fill()
        (title as NSString).draw(at: NSPoint(x: 16, y: 10),
                                 withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black])
    }

    override func cacheDisplay(in rect: NSRect, to bitmapImageRep: NSBitmapImageRep) {
        // This test assumes renderedTitle captures through cacheDisplay before the next poll.
        super.cacheDisplay(in: rect, to: bitmapImageRep)
        captures += 1
        if captures == 1 { DispatchQueue.main.async { self.title = "Ready" } }
    }
}

private struct CaptionButtonHost {
    let root: NSView
    let button: ChangingHistoryCaptionButton
    let window: NSWindow
}

private extension SkillHistoryLayoutTests {
    func captionHost() -> CaptionButtonHost {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let button = ChangingHistoryCaptionButton(frame: NSRect(x: 20, y: 20, width: 180, height: 40))
        button.title = "Loading"
        button.bezelStyle = .rounded
        root.addSubview(button)
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.orderFront(nil)
        return CaptionButtonHost(root: root, button: button, window: window)
    }

    func countFixture() throws -> AnyView {
        let skill = installedHistorySkill()
        let result = historyTimelineResult(rowCount: 12)
        let history = historyOwner(read: { _, _, _ in result })
        let tab = InstalledSkillHistoryView(
            skill: skill, currentBody: "# Current", origin: try XCTUnwrap(skill.installedOrigin),
            updateAvailable: false, localRevision: .initial, onOpenUpdates: {}, onUpdateCheck: { _ in },
            history: history
        )
        return AnyView(tab)
    }

    func settledDots(
        in view: NSView,
        expecting count: Int,
        timeout: TimeInterval = TestWait.hostedActionTimeoutSeconds
    ) async throws -> [CGFloat] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        var previous: [CGFloat]?
        var settled: [CGFloat]?
        repeat {
            view.layoutSubtreeIfNeeded()
            let dots = HistoryPixels.capture(in: view)?.positions.rowTops
            if let dots, dots == previous {
                settled = dots
                if dots.count == count { return dots }
            } else {
                settled = nil
            }
            previous = dots
            try await Task.sleep(for: .milliseconds(10))
        } while clock.now < deadline
        // A stable wrong count reaches the caller's count assertion, rather than a load timeout.
        return try XCTUnwrap(settled, "History marker positions did not settle within \(timeout) s")
    }
}
