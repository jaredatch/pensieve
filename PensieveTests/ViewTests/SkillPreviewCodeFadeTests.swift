import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class SkillPreviewCodeFadeTests: XCTestCase {
    func testLongLineFadesAtTheRightEdgeUntilItsEnd() async throws {
        let fixture = CodeFadeHost(count: 160)
        defer { fixture.close() }
        try await fixture.ready()
        try fixture.assertFullBand()

        try await fixture.scroll(toHiddenText: 180)
        try fixture.assertFullBand()

        try await fixture.scroll(toHiddenText: 12)
        let nearEnd = try fixture.paint()
        nearEnd.assertStrength(1, inset: 18)
        nearEnd.assertFaded(inset: 4)

        try await fixture.scroll(toHiddenText: -1)
        XCTAssertGreaterThan(fixture.remainingScroll, 8, "The last character must show before trailing padding does")
        try fixture.assertLastGlyphsUnfaded()

        try await fixture.scrollToLimit()
        try fixture.assertLastGlyphsUnfaded()
        let atEnd = try fixture.paint()
        atEnd.assertStrength(1, inset: atEnd.block.width - 4)
    }

    func testFadeFollowsTheColumnWidth() async throws {
        let fixture = CodeFadeHost(count: 80)
        defer { fixture.close() }
        try await fixture.ready()
        try fixture.assertFullBand()

        try await fixture.resizeToEndInset(6)
        XCTAssertGreaterThan(fixture.remainingScroll, 3, "Only trailing padding should still overflow")
        try fixture.assertLastGlyphsUnfaded()

        try await fixture.resizeToEndInset(30)
        XCTAssertEqual(fixture.remainingScroll, 0, accuracy: 1)
        try fixture.assertLastGlyphsUnfaded()

        fixture.resize(width: 360)
        try await fixture.ready()
        XCTAssertGreaterThan(fixture.hiddenText, 24)
        try fixture.assertFullBand()
    }

    func testReplacedDocumentShowsItsOwnFade() async throws {
        let fixture = CodeFadeHost(count: 44)
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.resizeToEndInset(8)
        try fixture.assertLastGlyphsUnfaded()

        try await fixture.replace(count: 160)
        try fixture.assertFullBand()
        try await fixture.scrollToLimit()
        try fixture.assertLastGlyphsUnfaded()

        try await fixture.replace(count: 120)
        XCTAssertEqual(fixture.block.contentView.bounds.minX, 0, accuracy: 1,
                       "A replaced document starts at its own beginning")
        try fixture.assertFullBand()

        try await fixture.replace(count: 44)
        XCTAssertGreaterThanOrEqual(-fixture.hiddenText, 0)
        XCTAssertLessThan(-fixture.hiddenText, 24, "The fitting line must end inside the possible fade band")
        try fixture.assertLastGlyphsUnfaded()
    }
}

/// Drives the real preview; accessibility measures glyph ends, and pixels judge only the painted cue.
@MainActor
private final class CodeFadeHost {
    let host: NSHostingView<AnyView>
    let window: NSWindow
    var line: String
    var block: NSScrollView { descendants(host).compactMap { $0 as? NSScrollView }.first! }
    var text: NSAccessibilityProtocol {
        elements(block).first { ($0.accessibilityValue() as? String) == line }!
    }
    var viewport: NSRect { window.convertToScreen(block.convert(block.bounds, to: nil)) }
    var end: NSRect { text.accessibilityFrame(for: NSRange(location: line.utf16.count - 1, length: 1)) }
    var hiddenText: CGFloat { end.maxX - viewport.maxX }
    var remainingScroll: CGFloat {
        max(0, (block.documentView?.bounds.maxX ?? 0) - block.documentVisibleRect.maxX)
    }

    init(count: Int) {
        line = String(repeating: "█", count: count)
        host = NSHostingView(rootView: Self.preview(line))
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 360, height: 180),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = host
        window.orderFront(nil)
    }

    func close() {
        window.close()
        window.contentView = nil
    }

    func ready() async throws {
        await TestWait.until(failureMessage: "The production code block and its glyphs must finish layout") {
            self.host.layoutSubtreeIfNeeded()
            guard let block = self.descendants(self.host).compactMap({ $0 as? NSScrollView }).first,
                  block.bounds.width > 0 else { return false }
            return self.elements(block).contains { ($0.accessibilityValue() as? String) == self.line }
        }
        // Allow the layout-driven paint update to reach the host before capturing it.
        try await Task.sleep(for: .milliseconds(100))
        host.displayIfNeeded()
        XCTAssertGreaterThan(end.width, 0, "The real text must expose glyph bounds")
    }

    func replace(count: Int) async throws {
        line = String(repeating: "█", count: count)
        host.rootView = Self.preview(line)
        try await ready()
    }

    func resize(width: CGFloat) {
        window.setContentSize(NSSize(width: width, height: 180))
        host.layoutSubtreeIfNeeded()
    }

    func resizeToEndInset(_ inset: CGFloat) async throws {
        resize(width: window.frame.width + hiddenText + inset)
        try await ready()
        XCTAssertEqual(-hiddenText, inset, accuracy: 1, "Fixture must put the last character at the requested edge")
    }

    func scroll(toHiddenText target: CGFloat) async throws {
        // Wheel deltas are requests, not positions. Re-measure the actual glyph end after each event.
        for _ in 0..<8 {
            let delta = hiddenText - target
            if abs(delta) <= 1 { break }
            try wheel(delta)
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(hiddenText, target, accuracy: 1, "Fixture must reach the measured hidden-text distance")
    }

    func scrollToLimit() async throws {
        try wheel(10_000)
        await TestWait.until(failureMessage: "Sideways input must reach the scrolling limit") {
            self.host.layoutSubtreeIfNeeded()
            return self.remainingScroll < 0.5
        }
        try await Task.sleep(for: .milliseconds(100))
    }

    func wheel(_ delta: CGFloat) throws {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                         wheel1: 0, wheel2: -Int32(delta.rounded()), wheel3: 0))
        block.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
    }

    func assertFullBand() throws {
        XCTAssertGreaterThan(hiddenText, 24, "Fixture needs text beyond the entire band")
        let pixels = try paint()
        pixels.assertStrength(1, inset: 28)
        let strengths = [20.0, 12.0, 4.0].map { pixels.assertFaded(inset: $0) }
        XCTAssertGreaterThan(strengths[0] - strengths[1], 0.15, "The inner half must fade gradually")
        XCTAssertGreaterThan(strengths[1] - strengths[2], 0.15, "The outer half must keep fading")
        for (strength, expected) in zip(strengths, [20.0 / 24, 0.5, 4.0 / 24]) {
            XCTAssertEqual(strength, expected, accuracy: 0.12, "The text must fade evenly across the band")
        }
    }

    func assertLastGlyphsUnfaded() throws {
        XCTAssertLessThanOrEqual(hiddenText, 0.5, "The last character must be fully visible")
        let pixels = try paint()
        let inset = -hiddenText
        pixels.assertStrength(1, inset: inset + 3)
        pixels.assertStrength(1, inset: inset + 9)
    }

    func paint() throws -> CodeFadePixels {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let rect = host.convert(block.bounds, from: block)
        return try CodeFadePixels(bitmap: bitmap, bounds: host.bounds, block: rect)
    }

    private static func preview(_ line: String) -> AnyView {
        AnyView(SkillPreviewView(markdownBody: "```\n\(line)\n```", scrolls: false)
            .environment(\.colorScheme, .light).background(.white))
    }

    private func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants)
    }

    private func elements(_ root: NSView) -> [NSAccessibilityProtocol] {
        var pending: [Any] = [root]
        var visited: Set<ObjectIdentifier> = []
        var result: [NSAccessibilityProtocol] = []
        while let candidate = pending.popLast() {
            guard let object = candidate as? NSObject, visited.insert(ObjectIdentifier(object)).inserted,
                  let element = candidate as? NSAccessibilityProtocol else { continue }
            result.append(element)
            pending.append(contentsOf: element.accessibilityChildren() ?? [])
            if let view = candidate as? NSView { pending.append(contentsOf: view.subviews) }
        }
        return result
    }
}

private struct CodeFadePixels {
    let bitmap: NSBitmapImageRep
    let block: NSRect
    let scale: CGFloat

    init(bitmap: NSBitmapImageRep, bounds: NSRect, block: NSRect) throws {
        self.bitmap = bitmap
        self.block = block
        scale = CGFloat(bitmap.pixelsWide) / bounds.width
        XCTAssertLessThan(ink(at: block.midX), 0.6, "The capture must contain visible code text")
    }

    /// Compare dense glyph ink at mid-height against the same glyphs in the middle and the bare fill above.
    func strength(inset: CGFloat) -> Double {
        let fill = value(x: block.midX, y: block.minY + 5)
        return (fill - ink(at: block.maxX - inset)) / (fill - ink(at: block.midX))
    }

    @discardableResult
    func assertFaded(inset: CGFloat) -> Double {
        let result = strength(inset: inset)
        XCTAssertGreaterThan(result, 0.03, "Faded text must still show ink, rather than being clipped or blanked")
        XCTAssertLessThan(result, 0.94, "Text \(inset) pt from the right edge must be paler than the middle")
        return result
    }

    func assertStrength(_ expected: Double, inset: CGFloat) {
        XCTAssertEqual(strength(inset: inset), expected, accuracy: 0.07,
                       "Text \(inset) pt from the edge must retain full strength")
    }

    private func ink(at x: CGFloat) -> Double {
        (-2...2).flatMap { dy in
            [-0.5, 0, 0.5].map { dx in value(x: x + dx, y: block.midY + CGFloat(dy)) }
        }.min() ?? 1
    }

    private func value(x: CGFloat, y: CGFloat) -> Double {
        guard let color = bitmap.colorAt(x: Int((x * scale).rounded()), y: Int((y * scale).rounded()))?
            .usingColorSpace(.deviceRGB) else { return 1 }
        return (color.redComponent + color.greenComponent + color.blueComponent) / 3
    }
}
