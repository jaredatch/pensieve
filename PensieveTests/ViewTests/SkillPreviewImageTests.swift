import AppKit
import MarkdownUI
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class SkillPreviewImageTests: XCTestCase {
    func testBlockAndInlineRemoteImagesMakeNoNetworkRequests() async throws {
        let network = PreviewNetworkTrap()
        let token = UUID().uuidString
        let markdown = """
        ![Block diagram](https://preview.example/\(token)/block.png)

        Text ![Inline diagram](https://preview.example/\(token)/inline.png) continues.
        """
        var appeared = false
        let host = NSHostingView(rootView: SkillPreviewView(markdownBody: markdown, scrolls: false)
            .markdownImageProvider(network)
            .markdownInlineImageProvider(network)
            .onAppear { appeared = true })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        window.display()
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(appeared, "The test must mount the preview before measuring its requests")
        XCTAssertEqual(network.requests, [], "Preview must never ask the inherited network image providers")
    }
}

/// Replaces both inherited MarkdownUI network providers with recording refusals. A preview that
/// forgets its own provider calls these instead. Never forwards or opens a socket. It proves provider
/// replacement, not the behavior of URLSession or third-party default loaders.
private final class PreviewNetworkTrap: ImageProvider, InlineImageProvider {
    private let lock = NSLock()
    private var recorded: [URL] = []

    var requests: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func record(_ url: URL?) {
        lock.lock()
        defer { lock.unlock() }
        if let url { recorded.append(url) }
    }

    func makeImage(url: URL?) -> some View {
        record(url)
        return Text("Inherited network block provider")
    }

    func image(with url: URL, label: String) async throws -> Image {
        record(url)
        throw URLError(.resourceUnavailable)
    }

}
