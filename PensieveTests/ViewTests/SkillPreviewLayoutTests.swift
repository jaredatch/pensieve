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
            window.animationBehavior = .none
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
        let ratios: [(String, CGFloat)] = [("One", 2), ("Two", 1.5), ("Three", 1.25),
                                          ("Four", 1), ("Five", 0.875), ("Six", 0.85)]
        let texts = try await settledTexts(["Body."] + ratios.map(\.0), in: fixture.host)
        let bodySize = try fontSize(of: XCTUnwrap(texts["Body."]))
        for (label, ratio) in ratios {
            let heading = try XCTUnwrap(texts[label])
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
        let texts = try await settledTexts(["Paragraph.", "Bullet", "Nested", "1.", "Numbered"], in: fixture.host)
        let leading = try XCTUnwrap(texts["Paragraph."]).accessibilityFrame().minX
        for (label, indent) in [("Bullet", CGFloat(26)), ("Nested", CGFloat(52)), ("Numbered", CGFloat(26))] {
            let item = try XCTUnwrap(texts[label])
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
        let content = "A list item whose text wraps over multiple lines in a deliberately narrow column."
        let fixture = host("- \(content)", width: 240)
        defer { fixture.window.close() }
        fixture.host.appearance = NSAppearance(named: .aqua)
        let item = try await text(content, in: fixture.host)
        let capture = try await bulletCenter(in: fixture.host, window: fixture.window, item: item)
        let firstLine = capture.firstLine
        XCTAssertGreaterThan(firstLine.height, 0, "The rendered first line must expose its vertical bounds")
        XCTAssertGreaterThan(item.accessibilityRange(forLine: 2).length, 0, "The hosted item must wrap to at least three lines")
        let center = capture.center
        XCTAssertGreaterThanOrEqual(center, firstLine.minY, "The bullet center must be inside the first line")
        XCTAssertLessThanOrEqual(center, firstLine.maxY, "The bullet center must be inside the first line")
    }

    func testWideNumberedMarkersStayInsideColumn() async throws {
        for locale in ["en_US", "de_DE", "ar_EG"] {
            let fixture = host("Paragraph.\n\n999. Three digits\n1000. Four digits\n1001. Next",
                               locale: Locale(identifier: locale))
            defer { fixture.window.close() }
            let pairs = [("999.", "Three digits"), ("1000.", "Four digits"), ("1001.", "Next")]
            let texts = try await settledTexts(["Paragraph."] + pairs.flatMap { [$0.0, $0.1] }, in: fixture.host)
            let leading = try XCTUnwrap(texts["Paragraph."]).accessibilityFrame().minX
            for (marker, item) in pairs {
                let markerText = try XCTUnwrap(texts[marker])
                let itemFrame = try XCTUnwrap(texts[item]).accessibilityFrame()
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
        window.animationBehavior = .none
        window.contentView = host
        window.orderFront(nil)
        return (host, window)
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
        window.animationBehavior = .none
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

// The hosted-text readers: how a test reaches rendered text and the bullet's pixels.
extension SkillPreviewLayoutTests {
    private func text(_ value: String, in host: NSHostingView<AnyView>) async throws -> NSAccessibilityProtocol {
        let texts = try await settledTexts([value], in: host)
        return try XCTUnwrap(texts[value])
    }

    /// Drain the live host's render work, including preference transactions and AppKit overlays. The async render
    /// probe rejects pending transactions and work that still requires the main thread; equal AX readings cannot
    /// establish that. It checks render readiness, never an expected indent, marker width or bullet position.
    private func settledTexts(
        _ values: [String], in host: NSHostingView<AnyView>
    ) async throws -> [String: NSAccessibilityProtocol] {
        var found: [String: NSAccessibilityProtocol] = [:]
        var renderReady = false
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                             failureMessage: "Rendered text \(values) must finish hosted layout",
                             diagnostics: { "renderReady=\(renderReady) | \(self.hostedLayoutDescription(host))" }, {
            host._renderForTest(interval: 0)
            let elements = self.elements(in: host)
            found = [:]
            for value in values {
                guard let element = elements.first(where: {
                    ($0.accessibilityValue() as? String) == value && $0.accessibilityFrame().width > 0
                }) else { continue }
                found[value] = element
            }
            renderReady = host._renderAsyncForTest(interval: 0)
            return found.count == values.count && renderReady
        })
        for value in values where found[value] == nil {
            XCTFail("Rendered text '\(value)' never appeared")
        }
        return found
    }

    /// What a failed wait saw: each accessible text with its frame, the texts SwiftUI rendered, and the window.
    private func hostedLayoutDescription(_ host: NSView) -> String {
        let accessible = elements(in: host).compactMap { element -> String? in
            guard let value = element.accessibilityValue() as? String, !value.isEmpty else { return nil }
            let frame = element.accessibilityFrame()
            return "'\(value.prefix(24))'@\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
        }
        let rendered = RenderedViewTestSupport.values(in: host).compactMap { $0 as? Text }
            .flatMap(RenderedViewTestSupport.strings).filter { !$0.isEmpty }
        let window = host.window
        return "window visible=\(window?.isVisible ?? false) occlusion=\(window?.occlusionState.rawValue ?? 0)"
            + " | accessible: \(accessible.joined(separator: "; "))"
            + " | rendered: \(rendered.map { $0.prefix(24) })"
    }

    /// Capture only after the host accepts an async render. cacheDisplay can itself lay out the host, so read the
    /// item's frame and first-line bounds after that capture, together on the main actor without another render.
    private func bulletCenter(
        in host: NSHostingView<AnyView>, window: NSWindow, item: NSAccessibilityProtocol
    ) async throws -> (center: CGFloat, firstLine: CGRect) {
        var capture: (center: CGFloat, firstLine: CGRect)?
        var lastError: Error?
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                             failureMessage: "The real bullet must produce visible gutter pixels",
                             diagnostics: { "\(String(describing: lastError)) | \(self.hostedLayoutDescription(host))" }, {
            host._renderForTest(interval: 0)
            guard host._renderAsyncForTest(interval: 0) else { return false }
            do {
                capture = try self.bulletCenterOnce(in: host, window: window, item: item)
                return true
            } catch {
                lastError = error
                return false
            }
        })
        if let capture { return capture }
        throw lastError ?? CocoaError(.coderInvalidValue)
    }

    private struct CaptureNotReady: Error, CustomStringConvertible { let description: String }

    private func bulletCenterOnce(
        in host: NSView, window: NSWindow, item: NSAccessibilityProtocol
    ) throws -> (center: CGFloat, firstLine: CGRect) {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let itemFrame = item.accessibilityFrame()
        let firstLine = item.accessibilityFrame(for: NSRange(location: 0, length: 1))
        let lineHeight = firstLine.height
        let screen = window.convertToScreen(host.convert(host.bounds, to: nil))
        let scaleX = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / host.bounds.height
        // Only the bullet occupies the gutter before the item's text; bitmap Y increases downward.
        let gutterEdge = (itemFrame.minX - screen.minX - 4) * scaleX
        let scanTop = (screen.maxY - itemFrame.maxY - lineHeight) * scaleY
        let itemBottom = (screen.maxY - itemFrame.minY) * scaleY
        guard [scaleX, scaleY, gutterEdge, scanTop, itemBottom, lineHeight].allSatisfy(\.isFinite),
              scaleX > 0, scaleY > 0, lineHeight > 0 else {
            throw CaptureNotReady(description: "no finite, positive host geometry; item=\(itemFrame) host=\(screen)")
        }
        let gutterEnd = Int(min(CGFloat(bitmap.pixelsWide), max(0, gutterEdge)))
        let top = Int(min(CGFloat(bitmap.pixelsHigh), max(0, scanTop)))
        let bottom = Int(min(CGFloat(bitmap.pixelsHigh), max(0, itemBottom)))
        guard gutterEnd > 0, top < bottom else {
            throw CaptureNotReady(description: "empty gutter or vertical range; item=\(itemFrame) host=\(screen)")
        }
        let gutter = 0..<gutterEnd
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
        guard let first = rows.first, let last = rows.last else {
            throw CaptureNotReady(description:
                "no gutter pixels; item=\(itemFrame) host=\(screen) gutterEnd=\(gutterEnd) rows=\(top)..<\(bottom)")
        }
        guard first > top else {
            throw CaptureNotReady(description: "bullet pixels touch the scan's top edge; item=\(itemFrame) host=\(screen)")
        }
        return (screen.maxY - CGFloat(first + last + 1) / (2 * scaleY), firstLine)
    }
}

@MainActor private final class LayoutMeasurements {
    var heights: [String: CGFloat] = [:]
}
