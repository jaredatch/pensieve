import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class SkillPreviewLayoutTests: XCTestCase {
    func testShortDocumentKeepsHeadingAtColumnLeadingPadding() async throws {
        for scrolls in [false, true] {
            let width: CGFloat = 800
            let host = NSHostingView(rootView: SkillPreviewView(markdownBody: "# Short\nA note.", scrolls: scrolls)
                .frame(width: width, height: 300))
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 300),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            window.orderFront(nil)

            var heading: NSAccessibilityProtocol?
            await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                                 failureMessage: "Short heading must finish hosted layout") {
                host.layoutSubtreeIfNeeded()
                heading = self.elements(in: host).first {
                    ($0.accessibilityValue() as? String) == "Short" && $0.accessibilityFrame().width > 0
                }
                return heading != nil
            }
            let headingFrame = try XCTUnwrap(heading).accessibilityFrame()
            let columnFrame = window.convertToScreen(host.convert(host.bounds, to: nil))
            XCTAssertEqual(headingFrame.minX - columnFrame.minX, 16, accuracy: 1,
                           "First heading must start at the column's 16 pt leading padding; scrolls=\(scrolls)")
        }
    }

    func testRenderedBodyUses13PointText() async throws {
        let fixture = host("Body text.")
        defer { fixture.window.close() }
        let body = try await text("Body text.", in: fixture.host)
        XCTAssertEqual(try fontSize(of: body), 13, accuracy: 0.01, "Rendered body must use the requested 13 pt size")
    }

    func testRenderedHeadingsUseGitHubRatios() async throws {
        let fixture = host("# One\n\n## Two\n\n### Three\n\n#### Four\n\n##### Five\n\n###### Six\n\nBody.")
        defer { fixture.window.close() }
        let body = try await text("Body.", in: fixture.host)
        let bodySize = try fontSize(of: body)
        let ratios: [(String, CGFloat)] = [("One", 2), ("Two", 1.5), ("Three", 1.25),
                                          ("Four", 1), ("Five", 0.875), ("Six", 0.85)]
        for (label, ratio) in ratios {
            let heading = try await text(label, in: fixture.host)
            // MarkdownUI 2.4.1 rounds all fonts to whole points, including em-scaled fonts.
            XCTAssertEqual(try fontSize(of: heading), (bodySize * ratio).rounded(), accuracy: 0.01,
                           "\(label) must retain its Primer heading/body ratio at whole-point precision")
        }
    }

    func testFirstTwoHeadingLevelsIncludeBottomRule() async throws {
        for (prefix, size) in [("#", CGFloat(26)), ("##", CGFloat(19.5))] {
            let measurements = LayoutMeasurements()
            let fixture = measuredHost(VStack {
                measured(SkillPreviewView(markdownBody: "\(prefix) Heading", scrolls: false),
                         as: "heading", into: measurements)
                measured(Text("Heading").font(.system(size: size.rounded(), weight: .semibold))
                    .lineHeight(.multiple(factor: 1.25)), as: "text", into: measurements)
            })
            defer { fixture.window.close() }
            await waitForMeasurements(measurements, in: fixture.host)
            // The heading's intrinsic block includes .3em padding and the scaled 1px rule below its text.
            let belowText = try XCTUnwrap(measurements.heights["heading"]) - 32 -
                XCTUnwrap(measurements.heights["text"])
            XCTAssertEqual(belowText, size * 0.3 + 13.0 / 16, accuracy: 0.01,
                           "\(prefix) must include the bottom rule as well as its CSS padding")
        }
    }

    func testListTextUsesTwoEmIndentAtEveryLevel() async throws {
        let fixture = host("Paragraph.\n\n- Bullet\n  - Nested\n\n1. Numbered")
        defer { fixture.window.close() }
        let paragraph = try await text("Paragraph.", in: fixture.host)
        let leading = paragraph.accessibilityFrame().minX
        for (label, indent) in [("Bullet", CGFloat(26)), ("Nested", CGFloat(52)), ("Numbered", CGFloat(26))] {
            let item = try await text(label, in: fixture.host)
            XCTAssertEqual(item.accessibilityFrame().minX - leading, indent, accuracy: 0.5,
                           "\(label) text must begin 2em from its parent block's leading edge")
        }
    }

    func testConsecutiveParagraphsUseScaledBlockGap() async throws {
        let measurements = LayoutMeasurements()
        let fixture = measuredHost(VStack {
            measured(SkillPreviewView(markdownBody: "Paragraph.\n\nParagraph.", scrolls: false),
                     as: "pair", into: measurements)
            measured(SkillPreviewView(markdownBody: "Paragraph.", scrolls: false),
                     as: "single", into: measurements)
        })
        defer { fixture.window.close() }
        await waitForMeasurements(measurements, in: fixture.host)
        let gap = try XCTUnwrap(measurements.heights["pair"]) -
            2 * XCTUnwrap(measurements.heights["single"]) + 32
        XCTAssertEqual(gap, 12, accuracy: 0.01, "Paragraphs must use the scaled 16px block gap")
    }

    func testFailedImageInListKeepsPlaceholderLayout() async throws {
        let alt = Array(repeating: "Missing diagram with a long description", count: 8).joined(separator: " ")
        // Compensate for the list indent so both real placeholders receive the same content width.
        let outside = host("![\(alt)](https://preview.example/missing.png)", width: 300)
        let inside = host("- ![\(alt)](https://preview.example/missing.png)", width: 300 + DesignTokens.markdownListIndent)
        defer { outside.window.close(); inside.window.close() }
        let outsideText = try await text(alt, in: outside.host)
        let insideText = try await text(alt, in: inside.host)
        XCTAssertEqual(insideText.accessibilityFrame().height, outsideText.accessibilityFrame().height, accuracy: 0.5,
                       "At equal content width, a list must preserve the placeholder's wrapping and height")
    }

    func testWrappedBulletSitsInsideFirstLine() async throws {
        let content = "A list item whose text wraps across three lines in a deliberately narrow column."
        let fixture = host("- \(content)", width: 240)
        defer { fixture.window.close() }
        fixture.host.appearance = NSAppearance(named: .aqua)
        let item = try await text(content, in: fixture.host)
        let firstLine = item.accessibilityFrame(for: NSRange(location: 0, length: 1))
        XCTAssertGreaterThan(firstLine.height, 0, "The rendered first line must expose its vertical bounds")
        XCTAssertGreaterThan(item.accessibilityRange(forLine: 2).length, 0, "The hosted item must have a third line")
        XCTAssertEqual(item.accessibilityRange(forLine: 3).length, 0, "The hosted item must wrap to exactly three lines")
        let center = try bulletCenter(in: fixture.host, window: fixture.window, itemFrame: item.accessibilityFrame())
        XCTAssertGreaterThanOrEqual(center, firstLine.minY, "The bullet center must be inside the first line")
        XCTAssertLessThanOrEqual(center, firstLine.maxY, "The bullet center must be inside the first line")
    }

    private func bulletCenter(in host: NSView, window: NSWindow, itemFrame: CGRect) throws -> CGFloat {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let screen = window.convertToScreen(host.convert(host.bounds, to: nil))
        let scaleX = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / host.bounds.height
        // Only the bullet occupies the gutter before the item's text; bitmap Y increases downward.
        let gutter = 0..<Int((itemFrame.minX - screen.minX - 4) * scaleX)
        let top = max(0, Int((screen.maxY - itemFrame.maxY) * scaleY))
        let bottom = min(bitmap.pixelsHigh, Int((screen.maxY - itemFrame.minY) * scaleY))
        var rows: [Int] = []
        for y in top..<bottom {
            for x in gutter {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.5 else { continue }
                if max(color.redComponent, color.greenComponent, color.blueComponent) < 0.5 {
                    rows.append(y)
                    break
                }
            }
        }
        let first = try XCTUnwrap(rows.first, "The real bullet must produce visible gutter pixels")
        let last = try XCTUnwrap(rows.last)
        return screen.maxY - CGFloat(first + last + 1) / (2 * scaleY)
    }

    func testWideNumberedMarkersStayInsideColumn() async throws {
        for locale in ["en_US", "de_DE", "ar_EG"] {
            let fixture = host("Paragraph.\n\n999. Three digits\n1000. Four digits\n1001. Next",
                               locale: Locale(identifier: locale))
            defer { fixture.window.close() }
            let leading = try await text("Paragraph.", in: fixture.host).accessibilityFrame().minX
            for (marker, item) in [("999.", "Three digits"), ("1000.", "Four digits"), ("1001.", "Next")] {
                let markerText = try await text(marker, in: fixture.host)
                let itemFrame = try await text(item, in: fixture.host).accessibilityFrame()
                let font = NSFont.monospacedDigitSystemFont(ofSize: try fontSize(of: markerText), weight: .regular)
                let intrinsicWidth = NSAttributedString(string: marker, attributes: [.font: font]).size().width
                // AX reports the allocated marker frame, even if its glyphs spill outside it.
                // Independent font metrics prove that the full glyph run fits before the text.
                XCTAssertGreaterThanOrEqual(itemFrame.minX - leading + 0.5, intrinsicWidth + 4,
                                            "Wide numbered markers need their full intrinsic width inside the column")
            }
        }
    }

    private func host(
        _ markdown: String, width: CGFloat = 600, locale: Locale = .current
    ) -> (host: NSHostingView<AnyView>, window: NSWindow) {
        let host = NSHostingView(rootView: AnyView(SkillPreviewView(markdownBody: markdown, scrolls: false)
            .environment(\.locale, locale)))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return (host, window)
    }

    private func text(_ value: String, in host: NSView) async throws -> NSAccessibilityProtocol {
        var found: NSAccessibilityProtocol?
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                             failureMessage: "Rendered text '\(value)' must finish hosted layout") {
            host.layoutSubtreeIfNeeded()
            found = self.elements(in: host).first {
                ($0.accessibilityValue() as? String) == value && $0.accessibilityFrame().width > 0
            }
            return found != nil
        }
        return try XCTUnwrap(found)
    }

    private func fontSize(of element: NSAccessibilityProtocol) throws -> CGFloat {
        let attributed = try XCTUnwrap(element.accessibilityAttributedString(for: NSRange(location: 0, length: 1)))
        // AppKit accessibility uses AXFont/AXFontSize dictionaries rather than NSAttributedString's font key.
        let font = try XCTUnwrap(attributed.attribute(NSAttributedString.Key("AXFont"), at: 0,
                                                     effectiveRange: nil) as? [String: Any])
        return CGFloat(try XCTUnwrap(font["AXFontSize"] as? NSNumber).doubleValue)
    }

    private func measured<V: View>(_ view: V, as name: String, into measurements: LayoutMeasurements) -> some View {
        view.fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                MainActor.assumeIsolated { measurements.heights[name] = height }
            }
    }

    private func measuredHost<V: View>(_ view: V) -> (host: NSHostingView<AnyView>, window: NSWindow) {
        let host = NSHostingView(rootView: AnyView(view.frame(width: 600)))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return (host, window)
    }

    private func waitForMeasurements(_ measurements: LayoutMeasurements, in host: NSView) async {
        var previous: [String: CGFloat] = [:]
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                             failureMessage: "Rendered block measurements must settle",
                             diagnostics: { "heights=\(measurements.heights)" }, {
            host.layoutSubtreeIfNeeded()
            let current = measurements.heights
            defer { previous = current }
            return current.count == 2 && current.values.allSatisfy { $0 > 0 } && previous == current
        })
    }

    private func elements(in root: NSView) -> [NSAccessibilityProtocol] {
        var pending: [Any] = [root] + NSAccessibility.unignoredChildrenForOnlyChild(from: root)
        var visited: Set<ObjectIdentifier> = []
        var result: [NSAccessibilityProtocol] = []
        while let candidate = pending.popLast() {
            guard let object = candidate as? NSObject,
                  visited.insert(ObjectIdentifier(object)).inserted,
                  let element = candidate as? NSAccessibilityProtocol else { continue }
            result.append(element)
            pending.append(contentsOf: element.accessibilityChildren() ?? [])
            if let view = candidate as? NSView { pending.append(contentsOf: view.subviews) }
        }
        return result
    }
}

@MainActor private final class LayoutMeasurements {
    var heights: [String: CGFloat] = [:]
}
