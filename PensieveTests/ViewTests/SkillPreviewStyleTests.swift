import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class SkillPreviewStyleTests: XCTestCase {
    func testMetadataTableRowsShareOneBackground() throws {
        let rows = SkillFrontmatterRow.rows(from: SkillParser.parse("""
        ---
        name: Example
        description: Description
        license: MIT
        author: Someone
        ---
        """))
        let paint = try render(SkillFrontmatterTable(rows: rows))
        try assertPlainRows(paint, gutter: 4, count: 4)
    }

    func testMarkdownTableRowsShareOneBackground() throws {
        let paint = try render(preview("""
        | Key | Value |
        | --- | --- |
        | First | One |
        | Second | Two |
        | Third | Three |
        | Fourth | Four |
        """))
        try assertPlainRows(paint, gutter: 20, count: 5)
    }

    func testInlineCodeFillIsLighterThanBefore() throws {
        for prefix in ["", "### "] {
            let paint = try render(preview(prefix + "`MMMMMMMMMMMM`"))
            try assertLighterFill(paint, context: prefix.isEmpty ? "Paragraph code" : "Heading code")
        }
    }

    func testCodeBlockFillIsLighterThanBefore() throws {
        let paint = try render(preview("```\nMMMMMMMMMMMM\n```\n\nVisible body."))
        try assertLighterFill(paint, context: "Fenced code")
    }

    func testQuoteTextAndRuleAreDarkerThanBefore() throws {
        let paint = try render(preview("> Quoted words"))
        let quote = paint.minimum(x: 34..<180, y: 16..<40)
        let secondary = paint.minimum(x: 180..<270, y: 200..<240)
        let body = paint.minimum(x: 270..<360, y: 200..<240)
        let rule = paint.minimum(x: 17..<19, y: 18..<32)
        let separator = paint.value(135, 220)
        XCTAssertLessThanOrEqual(quote, secondary - 0.05, "Quote text must be darker than secondary text")
        XCTAssertGreaterThanOrEqual(quote, body + 0.10, "Quote text must remain quieter than body text")
        XCTAssertLessThanOrEqual(rule, separator - 0.02, "Quote rule must be darker than the shared separator")
        XCTAssertGreaterThan(rule, quote, "Quote rule must stay lighter than its text")
    }

    func testWideCodeBlockScrollsWithoutAScrollBar() async throws {
        let line = String(repeating: "abcdefghij", count: 12) + "END"
        let host = NSHostingView(rootView: preview("```\n\(line)\n```\n\n```\nShort\n```"))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 360, height: 260),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        var blocks: [NSScrollView] = []
        await TestWait.until(failureMessage: "Both production code blocks must finish hosted layout") {
            host.layoutSubtreeIfNeeded()
            blocks = self.descendants(host).compactMap { $0 as? NSScrollView }
            return blocks.count == 2 && blocks.allSatisfy { $0.bounds.height > 0 }
        }
        let wide = try XCTUnwrap(blocks.first { ($0.documentView?.frame.width ?? 0) > $0.contentSize.width })
        let short = try XCTUnwrap(blocks.first { $0 !== wide })
        for block in blocks { block.scrollerStyle = .legacy }
        host.layoutSubtreeIfNeeded()
        for block in blocks {
            XCTAssertEqual(block.scrollerStyle, .legacy, "Fixture must reproduce always-show scroll bars locally")
        }
        let text = try XCTUnwrap(elements(wide).first { ($0.accessibilityValue() as? String) == line })
        let endRange = NSRange(location: line.utf16.count - 3, length: 3)
        let startEnd = text.accessibilityFrame(for: endRange)
        let viewport = screenRect(wide.contentView, window: window)
        XCTAssertGreaterThan(startEnd.width, 0, "The actual line end must expose visible glyph bounds")
        XCTAssertGreaterThan(startEnd.minX, viewport.maxX, "The line end must start outside the block")
        let height = wide.frame.height
        let lineHeight = text.accessibilityFrame().height
        assertNoBar(wide)
        XCTAssertEqual(height, short.frame.height, accuracy: 0.5, "A wide line must not add scroller height")

        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                         wheel1: 0, wheel2: -Int32(ceil(startEnd.maxX - viewport.maxX + 8)), wheel3: 0))
        wide.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
        await TestWait.until(failureMessage: "Sideways wheel input must bring the line end into view") {
            host.layoutSubtreeIfNeeded()
            let end = text.accessibilityFrame(for: endRange)
            return end.minX >= viewport.minX && end.maxX <= viewport.maxX + 1
        }
        let end = text.accessibilityFrame(for: endRange)
        XCTAssertGreaterThanOrEqual(end.minX, viewport.minX)
        XCTAssertLessThanOrEqual(end.maxX, viewport.maxX + 1)
        try assertSingleLineVisible(text, in: wide, matching: short, height: lineHeight)
        assertNoBar(wide)
        XCTAssertEqual(wide.frame.height, height, accuracy: 0.5, "Scrolling must not change the block height")
    }

    private func assertSingleLineVisible(_ text: NSAccessibilityProtocol, in block: NSScrollView,
                                         matching short: NSScrollView, height: CGFloat) throws {
        XCTAssertEqual(text.accessibilityFrame().height, height, accuracy: 0.5,
                       "Sideways scrolling must never wrap the line")
        let shortText = try XCTUnwrap(elements(short).first { ($0.accessibilityValue() as? String) == "Short" })
        XCTAssertEqual(text.accessibilityFrame().height, shortText.accessibilityFrame().height, accuracy: 0.5,
                       "Long and short code must both stay one line high")
        // SwiftUI range accessibility rects have unstable Y coordinates; verify vertical exposure in the clip view.
        let document = try XCTUnwrap(block.documentView)
        XCTAssertLessThanOrEqual(block.documentVisibleRect.minY, document.bounds.minY + 0.5)
        XCTAssertGreaterThanOrEqual(block.documentVisibleRect.maxY, document.bounds.maxY - 0.5,
                                    "The entire one-line document must stay vertically visible")
    }

    private func preview(_ markdown: String) -> some View {
        SkillPreviewView(markdownBody: markdown, scrolls: false).environment(\.colorScheme, .light)
    }

    private func assertNoBar(_ block: NSScrollView, file: StaticString = #filePath, line: UInt = #line) {
        let visible = block.hasHorizontalScroller && !(block.horizontalScroller?.isHidden ?? true)
        XCTAssertFalse(visible, "Code blocks must hide the horizontal bar even in legacy style", file: file, line: line)
    }

    private func screenRect(_ view: NSView, window: NSWindow) -> NSRect {
        window.convertToScreen(view.convert(view.bounds, to: nil))
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

    private func assertPlainRows(_ paint: StylePixels, gutter: Int, count: Int) throws {
        let bands = paint.textBands(x: (gutter + 8)..<140)
        XCTAssertEqual(bands.count, count, "Every table row must contain visible text before sampling its padding")
        let page = paint.value(359, 190)
        for y in bands {
            XCTAssertEqual(paint.value(gutter, y), page, accuracy: 0.005, "Row at y=\(y) must share the page background")
        }
    }

    private func assertLighterFill(_ paint: StylePixels, context: String) throws {
        let fill = try XCTUnwrap(paint.dominantFill(), "\(context) must paint a visible background")
        let old = paint.value(45, 220)
        let page = paint.value(359, 190)
        XCTAssertGreaterThanOrEqual(fill, old + 0.02, "\(context) must be visibly lighter than quaternaryLabelColor")
        XCTAssertLessThanOrEqual(fill, page - 0.01, "\(context) must remain distinct from the page")
    }

    private func render<Content: View>(_ content: Content) throws -> StylePixels {
        let renderer = ImageRenderer(content: VStack(spacing: 0) {
            content.frame(width: 360, height: 200, alignment: .topLeading)
            HStack(spacing: 0) {
                Color(nsColor: .quaternaryLabelColor).frame(width: 90)
                Color(nsColor: .separatorColor).frame(width: 90)
                Text("Quoted words").foregroundStyle(.secondary).frame(width: 90)
                Text("Quoted words").foregroundStyle(.primary).frame(width: 90)
            }.font(.system(size: 13)).frame(height: 40)
        }.background(.white).environment(\.colorScheme, .light))
        renderer.scale = 1
        let paint = try StylePixels(image: XCTUnwrap(renderer.cgImage))
        XCTAssertLessThan(paint.minimum(x: 0..<360, y: 0..<200), 0.6,
                          "Production content must paint visible text before any color comparisons")
        return paint
    }
}

private struct StylePixels {
    let context: CGContext
    let pixels: UnsafeMutablePointer<UInt8>

    init(image: CGImage) throws {
        context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                         bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                            | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    }

    func value(_ x: Int, _ y: Int) -> Double {
        let offset = y * context.bytesPerRow + x * 4
        return Double(Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2])) / 765
    }

    func minimum(x: Range<Int>, y: Range<Int>) -> Double {
        y.flatMap { row in x.map { value($0, row) } }.min() ?? 1
    }

    func textBands(x: Range<Int>) -> [Int] {
        var bands: [Int] = []
        var previous = false
        for y in 0..<180 {
            let ink = x.contains { value($0, y) < 0.6 }
            if ink && !previous { bands.append(y) }
            previous = ink
        }
        return bands
    }

    func dominantFill() -> Double? {
        var counts: [Int: Int] = [:]
        for y in 0..<180 {
            for x in 16..<344 {
                let luma = value(x, y)
                if luma > 0.85 && luma < 0.995 { counts[Int((luma * 765).rounded()), default: 0] += 1 }
            }
        }
        guard let fill = counts.max(by: { $0.value < $1.value }), fill.value >= 300 else { return nil }
        return Double(fill.key) / 765
    }
}
