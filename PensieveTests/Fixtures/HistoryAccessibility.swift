import AppKit
import Vision

@MainActor
enum HistoryAccessibility {
    static func pressButton(titled title: String, in root: NSView) async -> Bool {
        var button: NSAccessibilityProtocol?
        var renderedTitles: [ObjectIdentifier: String] = [:]
        await TestWait.until(timeout: .seconds(TestWait.firstRenderTimeoutSeconds),
                             failureMessage: "The rendered '\(title)' button must be found") {
            button = findButton(titled: title, in: root, renderedTitles: &renderedTitles)
            return button != nil
        }
        guard let button else { return false }
        return press(button)
    }

    /// A missing native control permits the retry host's existing rendered-click fallback.
    /// False from AX after finding the control never permits that fallback.
    static func pressButtonIfFound(titled title: String, in root: NSView) -> Bool {
        var renderedTitles: [ObjectIdentifier: String] = [:]
        guard let button = findButton(titled: title, in: root, renderedTitles: &renderedTitles) else { return false }
        return press(button)
    }

    private static func press(_ button: NSAccessibilityProtocol) -> Bool {
        // SwiftUI can return false even when the action fires. Callers assert its result.
        _ = button.accessibilityPerformPress()
        return true
    }

    private static func findButton(
        titled title: String, in root: NSView, renderedTitles: inout [ObjectIdentifier: String]
    ) -> NSAccessibilityProtocol? {
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
            // Read each native caption once during this locate step. The caller has already
            // waited for History's rows or error state, so its rendered caption is ready.
            if let button = candidate as? NSButton {
                let identity = ObjectIdentifier(button)
                if renderedTitles[identity] == nil {
                    renderedTitles[identity] = renderedTitle(of: button) ?? ""
                }
                if renderedTitles[identity] == title { return button }
            }
            pending.append(contentsOf: element.accessibilityChildren() ?? [])
            pending.append(contentsOf: element.accessibilityChildrenInNavigationOrder() ?? [])
            if let view = candidate as? NSView { pending.append(contentsOf: view.subviews) }
        }
        return nil
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
