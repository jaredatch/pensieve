import AppKit
import Vision

@MainActor
enum HistoryAccessibility {
    static func pressButton(titled title: String, in root: NSView) -> Bool {
        root.layoutSubtreeIfNeeded()
        var pending: [Any] = [root]
        pending.append(contentsOf: NSAccessibility.unignoredChildrenForOnlyChild(from: root))
        var visited: Set<ObjectIdentifier> = []
        while let candidate = pending.popLast() {
            guard let object = candidate as? NSObject,
                  visited.insert(ObjectIdentifier(object)).inserted else { continue }
            guard let element = candidate as? NSAccessibilityProtocol else { continue }
            if element.accessibilityRole() == .button,
               [element.accessibilityTitle(), element.accessibilityLabel()].contains(title) {
                return element.accessibilityPerformPress()
            }
            // The test host can omit SwiftUI's accessibility labels. Its link-style button
            // still has a public NSButton backing: identify its rendered caption, then press it.
            // SwiftUI returns false even when this press fires the action. Report finding the
            // control; callers assert the resulting behavior rather than the AX return value.
            if let button = candidate as? NSButton, renderedTitle(of: button) == title {
                _ = button.accessibilityPerformPress()
                return true
            }
            pending.append(contentsOf: element.accessibilityChildren() ?? [])
            pending.append(contentsOf: element.accessibilityChildrenInNavigationOrder() ?? [])
            if let view = candidate as? NSView { pending.append(contentsOf: view.subviews) }
        }
        return false
    }

    private static func renderedTitle(of button: NSButton) -> String? {
        guard let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { return nil }
        button.cacheDisplay(in: button.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return nil }
        return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}
