import AppKit
import Vision

@MainActor
enum HistoryAccessibility {
    static func pressButton(titled title: String, in root: NSView) async -> Bool {
        let locator = ButtonLocator(title: title)
        var button: NSAccessibilityProtocol?
        await TestWait.until(timeout: .seconds(TestWait.firstRenderTimeoutSeconds),
                             failureMessage: "The rendered '\(title)' button must be found") {
            button = locator.find(in: root)
            return button != nil
        }
        guard let button else { return false }
        return press(button)
    }

    /// A missing native control permits the retry host's existing rendered-click fallback.
    /// False from AX after finding the control never permits that fallback.
    static func pressButtonIfFound(titled title: String, in root: NSView) -> Bool {
        guard let button = ButtonLocator(title: title).find(in: root) else { return false }
        return press(button)
    }

    private static func press(_ button: NSAccessibilityProtocol) -> Bool {
        // SwiftUI can return false even when the action fires. Callers assert its result.
        _ = button.accessibilityPerformPress()
        return true
    }

    private struct Caption {
        let bounds: NSRect
        let text: String?
    }

    /// One locator owns the lifetime of its poll cache. Object keys retain each button so
    /// its address cannot be reused; only a matching read at unchanged bounds is reusable.
    @MainActor
    final class ButtonLocator {
        private let title: String
        private var captions: [NSButton: Caption] = [:]

        init(title: String) { self.title = title }

        func find(in root: NSView) -> NSAccessibilityProtocol? {
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
                    return element
                }
                if let button = candidate as? NSButton {
                    if let cached = captions[button], cached.bounds == button.bounds,
                       cached.text?.isEmpty == false, cached.text == title {
                        return button
                    }
                    let caption = HistoryAccessibility.renderedTitle(of: button)
                    captions[button] = Caption(bounds: button.bounds, text: caption)
                    if caption == title { return button }
                }
                pending.append(contentsOf: element.accessibilityChildren() ?? [])
                pending.append(contentsOf: element.accessibilityChildrenInNavigationOrder() ?? [])
                if let view = candidate as? NSView { pending.append(contentsOf: view.subviews) }
            }
            return nil
        }
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
