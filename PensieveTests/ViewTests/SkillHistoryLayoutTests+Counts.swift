import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

extension SkillHistoryLayoutTests {
    func testUnlabeledButtonCaptionCanBecomeReadyAfterFirstPoll() async {
        let fixture = captionHost(title: "Loading")
        let button = fixture.button
        defer { fixture.window.close() }

        let pressed = await HistoryAccessibility.pressButton(titled: "Ready", in: fixture.root)
        XCTAssertTrue(pressed,
                      "A later poll must locate the newly rendered caption; title=\(button.title), reads=\(button.captures)")
        XCTAssertGreaterThan(button.captures, 1, "A stale OCR miss must be read again")
        XCTAssertEqual(button.presses, 1, "A caption becoming ready must still cause only one press")
    }

    func testMatchingCaptionReusesPixelsUntilButtonBoundsChange() {
        let fixture = captionHost(title: "Ready")
        defer { fixture.window.close() }
        let locator = HistoryAccessibility.ButtonLocator(title: "Ready")
        XCTAssertNotNil(locator.find(in: fixture.root))
        XCTAssertNotNil(locator.find(in: fixture.root))
        XCTAssertEqual(fixture.button.captures, 1, "A matching caption at unchanged bounds must reuse its capture")
        fixture.button.setFrameSize(NSSize(width: 200, height: 40))
        XCTAssertNotNil(locator.find(in: fixture.root))
        XCTAssertEqual(fixture.button.captures, 2, "Changed button bounds must refresh the captured caption")
        XCTAssertEqual(fixture.button.presses, 0, "Locating and caching must never press a button")
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

    override func accessibilityTitle() -> String? { nil }
    override func accessibilityLabel() -> String? { nil }
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

private struct CaptionHost {
    let root: NSView
    let button: ChangingHistoryCaptionButton
    let window: NSWindow
}

private extension SkillHistoryLayoutTests {
    func captionHost(title: String) -> CaptionHost {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let button = ChangingHistoryCaptionButton(frame: NSRect(x: 20, y: 20, width: 180, height: 40))
        button.title = title
        button.bezelStyle = .rounded
        root.addSubview(button)
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.orderFront(nil)
        return CaptionHost(root: root, button: button, window: window)
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
