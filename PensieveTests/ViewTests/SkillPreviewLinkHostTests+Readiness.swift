import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

extension SkillPreviewLinkHostTests {
    // Observe the same preference that the production onPreferenceChange delivers to HeadingTargets.
    // A prior observation plus a completed render drains both callbacks before the click.
    func waitForAnchorTargets(in host: NSHostingView<AnyView>, readiness: AnchorLayoutReadiness) async {
        var renderReady = false
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                             failureMessage: "Both duplicate heading preferences must finish delivery",
                             diagnostics: {
            self.reportAnchorState(in: host, details: "renderReady=\(renderReady) targets=\(readiness.targets)")
        }, {
            let delivered = readiness.targets
            host._renderForTest(interval: 0)
            host.layoutSubtreeIfNeeded()
            renderReady = host._renderAsyncForTest(interval: 0)
            return delivered.count == 2 && delivered.allSatisfy { $0.slug == "authoring-gate" && $0.position.isFinite }
                && Set(delivered.map(\.id)).count == 2 && delivered == readiness.targets && renderReady
        })
    }

    // The click disables animation. Once its changed origin has rendered without pending work,
    // the nonanimated scroll is applied; this never waits for First target's visibility or > 100.
    func waitForAnchorScroll(in host: NSHostingView<AnyView>, scroller: NSScrollView, origin: NSPoint) async {
        var renderReady = false
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                             failureMessage: "Anchor scroll must finish rendering",
                             diagnostics: { self.reportAnchorState(in: host, details: "renderReady=\(renderReady)") }, {
            host._renderForTest(interval: 0)
            host.layoutSubtreeIfNeeded()
            renderReady = host._renderAsyncForTest(interval: 0)
            return scroller.contentView.bounds.origin != origin && renderReady
        })
    }

    func reportAnchorState(in host: NSView, details: String = "") -> String {
        let scroller = views(host).compactMap { $0 as? NSScrollView }.first
        let headings = elements(host).filter { ($0.accessibilityValue() as? String) == "Authoring gate" }
            .map { String(describing: $0.accessibilityFrame()) }
        let state = "origin=\(String(describing: scroller?.contentView.bounds.origin)) headings=\(headings) | \(details)"
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

@MainActor final class AnchorLayoutReadiness {
    var targets: [SkillPreviewLinkPolicy.HeadingTarget] = []
}
