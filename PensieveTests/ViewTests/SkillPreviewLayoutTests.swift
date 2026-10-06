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
