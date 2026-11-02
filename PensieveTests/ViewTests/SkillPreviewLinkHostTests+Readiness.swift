import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

extension SkillPreviewLinkHostTests {
    func reportAnchorState(in host: NSView) -> String {
        let scroller = views(host).compactMap { $0 as? NSScrollView }.first
        let headings = elements(host).filter { ($0.accessibilityValue() as? String) == "Authoring gate" }
            .map { String(describing: $0.accessibilityFrame()) }
        let state = "origin=\(String(describing: scroller?.contentView.bounds.origin)) headings=\(headings)"
        XCTFail(state)
        return state
    }

    func elements(_ root: NSView) -> [NSAccessibilityProtocol] {
        var pending: [Any] = [root] + NSAccessibility.unignoredChildrenForOnlyChild(from: root)
        var visited: Set<ObjectIdentifier> = [], result: [NSAccessibilityProtocol] = []
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

    func views(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(views)
    }
}
