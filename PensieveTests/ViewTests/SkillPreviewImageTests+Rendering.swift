import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import Pensieve

extension SkillPreviewImageTests {
    func testProvidersProduceDecodedEmbeddedAndRelativeImages() async throws {
        let fixture = try imageFixture()
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        let embedded = "data:image/png;base64," + (try PreviewImageFixture.png()).base64EncodedString()
        let provider = PreviewImageProvider(loader: PreviewImageLoader(), skillDirectory: fixture.root)
        let reference = try PreviewImageFixture.decodedPNG()
        assertVisible(reference, "Decoded PNG reference")
        for source in [embedded, "red.png"] {
            let url = try XCTUnwrap(URL(string: source))
            let decoded = await provider.loadImage(url: url)
            let blockImage = try XCTUnwrap(decoded)
            assertVisible(blockImage, "Block provider decoded pixels")
            XCTAssertEqual(blockImage.width, reference.width)
            XCTAssertEqual(blockImage.height, reference.height)
            XCTAssertEqual(rgba(blockImage), rgba(reference))
            let block = ImageRenderer(content: PreviewBlockImageContent(image: blockImage, alt: "Diagram"))
            let blockCapture = try XCTUnwrap(block.cgImage)
            assertVisible(blockCapture, "Block provider content")
            XCTAssertEqual(blockCapture.width, reference.width)
            XCTAssertEqual(blockCapture.height, reference.height)
            XCTAssertEqual(rgba(blockCapture), rgba(reference))
            let inline = try await provider.image(with: url, label: "Diagram")
            let inlineCapture = try XCTUnwrap(ImageRenderer(content: inline).cgImage)
            assertVisible(inlineCapture, "Inline provider content")
            XCTAssertEqual(inlineCapture.width, reference.width)
            XCTAssertEqual(inlineCapture.height, reference.height)
            XCTAssertEqual(rgba(inlineCapture), rgba(reference))
        }
    }

    func testProvidersReturnPlaceholdersForEscapingAndUnsupportedURLs() async throws {
        let fixture = try imageFixture()
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        let provider = PreviewImageProvider(loader: PreviewImageLoader(), skillDirectory: fixture.root)
        let sources = ["../outside.png", "%2e%2e/outside.png", "file:///outside.png",
                       "https://preview.example/red.png", "http://preview.example/red.png",
                       "ftp://preview.example/red.png", "custom:red.png", "javascript:alert(1)"]
        for source in sources {
            let url = try XCTUnwrap(URL(string: source))
            let blockImage = await provider.loadImage(url: url)
            XCTAssertNil(blockImage, source)
            try assertPlaceholder(PreviewBlockImageContent(image: blockImage, alt: "Blocked diagram"),
                                  alt: "Blocked diagram", inline: false)
            let inline = try await provider.image(with: url, label: "Blocked diagram")
            try assertPlaceholder(inline, alt: "Blocked diagram", inline: true)
        }
    }

    func testFailedProvidersReturnPlaceholdersAndKeepValidInlineNeighbor() async throws {
        let fixture = try imageFixture()
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        try fixture.files.createSymlink(at: fixture.root + "/linked.png", pointingTo: fixture.root + "/red.png")
        XCTAssertEqual(mkfifo(fixture.root + "/pipe.png", 0o600), 0)
        try fixture.files.writeFile(at: fixture.root + "/invalid.png", content: "not an image")
        let reference = try PreviewImageFixture.decodedPNG()
        assertVisible(reference, "Decoded neighbor reference")
        for leaf in ["linked.png", "pipe.png", "unreadable.png", "invalid.png"] {
            let provider = PreviewImageProvider(loader: RecordingPreviewImageLoader(unreadableLeaf: "unreadable.png"),
                                                skillDirectory: fixture.root)
            let failedURL = try XCTUnwrap(URL(string: leaf))
            let blockImage = await provider.loadImage(url: failedURL)
            XCTAssertNil(blockImage, leaf)
            try assertPlaceholder(PreviewBlockImageContent(image: blockImage, alt: leaf), alt: leaf, inline: false)
            // Mirror MarkdownUI's throwing task group: a failure must return an image rather than
            // throw and discard the paragraph's whole image batch, including the valid neighbor.
            let images = try await withThrowingTaskGroup(of: (String, Image).self) { group in
                for source in [leaf, "red.png"] {
                    group.addTask { (source, try await provider.image(with: URL(string: source)!, label: source)) }
                }
                var result: [String: Image] = [:]
                for try await (source, image) in group { result[source] = image }
                return result
            }
            XCTAssertEqual(images.count, 2, leaf)
            try assertPlaceholder(XCTUnwrap(images[leaf]), alt: leaf, inline: true)
            let neighbor = try XCTUnwrap(ImageRenderer(content: XCTUnwrap(images["red.png"])).cgImage)
            assertVisible(neighbor, "Valid neighbor after \(leaf)")
            XCTAssertEqual(neighbor.width, 32)
            XCTAssertEqual(neighbor.height, 24)
            XCTAssertEqual(rgba(neighbor), rgba(reference), "The provider must retain the decoded neighbor after \(leaf)")
        }
    }

    private func assertPlaceholder<Content: View>(_ content: Content, alt: String, inline: Bool) throws {
        let actual = ImageRenderer(content: content.environment(\.colorScheme, .light))
        actual.scale = 2
        let expected = ImageRenderer(content: Label(alt.isEmpty ? "Image unavailable" : alt, systemImage: "photo")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: inline ? 320 : nil).fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, .light))
        expected.scale = 2
        let rendered = try XCTUnwrap(actual.cgImage)
        let reference = try XCTUnwrap(expected.cgImage)
        assertVisible(rendered, "Provider placeholder for \(alt)")
        assertVisible(reference, "Reference placeholder for \(alt)")
        XCTAssertEqual(rendered.width, reference.width)
        XCTAssertEqual(rendered.height, reference.height)
        assertRenderedTextMatches(rendered, reference, alt)
    }

    func testBlockAndInlineReadsAndDecodesStayOffMainThread() async throws {
        let fixture = try imageFixture()
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        let embedded = "data:image/png;base64," + (try PreviewImageFixture.png()).base64EncodedString()
        let blockLoader = RecordingPreviewImageLoader()
        let host = imageHost(markdown: "![Embedded](\(embedded))\n\n![Local](red.png)",
                             directory: fixture.root, loader: blockLoader)
        defer { host.window.close() }
        await TestWait.until(failureMessage: "Both block reads must finish") { blockLoader.results.count == 2 }
        XCTAssertEqual(blockLoader.results.filter(\.loaded).count, 2)
        XCTAssertFalse(blockLoader.results.contains(where: \.onMainThread), "Block reads and decodes must leave the main thread")

        let inlineLoader = RecordingPreviewImageLoader()
        let provider = PreviewImageProvider(loader: inlineLoader, skillDirectory: fixture.root)
        for url in [URL(string: embedded)!, URL(string: "red.png")!] {
            _ = try await provider.image(with: url, label: "Inline")
        }
        XCTAssertEqual(inlineLoader.results.filter(\.loaded).count, 2)
        XCTAssertFalse(inlineLoader.results.contains(where: \.onMainThread),
                       "Inline reads and decodes must leave the main thread")
    }

    func testMountedPreviewRoutesBlockAndInlineEmbeddedAndRelativeImages() async throws {
        let fixture = try imageFixture()
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        let dataURL = "data:image/png;base64," + (try PreviewImageFixture.png()).base64EncodedString()
        let markdown = """
        ![Embedded block](\(dataURL))

        ![Local block](red.png)

        Before ![Embedded inline](\(dataURL)) and ![Local inline](red.png) after.
        """
        let loader = RecordingPreviewImageLoader()
        let host = imageHost(markdown: markdown, directory: fixture.root, loader: loader)
        defer { host.window.close() }
        await TestWait.until(failureMessage: "Both block and inline image loaders must finish") { loader.results.count == 4 }
        XCTAssertEqual(loader.results.filter(\.loaded).count, 4)
        XCTAssertEqual(loader.results.filter { $0.url.scheme == "data" }.count, 2)
        let directory = URL(fileURLWithPath: fixture.root, isDirectory: true)
        let localFile = directory.appendingPathComponent("red.png").standardizedFileURL
        XCTAssertEqual(loader.results.filter {
            URL(string: $0.url.relativeString, relativeTo: directory)?.absoluteURL.standardizedFileURL == localFile
        }.count, 2)
    }

    func testMountedPreviewRoutesFailedInlineImageAndValidNeighbor() async throws {
        let fixture = try imageFixture()
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        try fixture.files.createSymlink(at: fixture.root + "/linked.png", pointingTo: fixture.root + "/red.png")
        XCTAssertEqual(mkfifo(fixture.root + "/pipe.png", 0o600), 0)
        try fixture.files.writeFile(at: fixture.root + "/invalid.png", content: "not image data")
        for leaf in ["linked.png", "pipe.png", "unreadable.png", "invalid.png"] {
            let loader = RecordingPreviewImageLoader(unreadableLeaf: "unreadable.png")
            let host = imageHost(markdown: "Before ![Failed \(leaf)](\(leaf)) and ![Valid neighbor](red.png) after.",
                                 directory: fixture.root, loader: loader)
            defer { host.window.close() }
            await TestWait.until(failureMessage: "Inline attempts must finish for \(leaf)") { loader.results.count == 2 }
            XCTAssertEqual(loader.results.filter(\.loaded).count, 1, leaf)
        }
    }

    func testBlockPlaceholderReceivesMarkdownAltText() throws {
        let loader = RecordingPreviewImageLoader()
        let longAlt = Array(repeating: "Long diagram description", count: 30).joined(separator: " ")
        let short = imageHost(markdown: "![](https://preview.example/short.png)", directory: nil, loader: loader, width: 320)
        defer { short.window.close() }
        let long = imageHost(markdown: "![\(longAlt)](https://preview.example/long.png)",
                             directory: nil, loader: loader, width: 320)
        defer { long.window.close() }
        XCTAssertLessThan(short.view.fittingSize.height, 100)
        XCTAssertGreaterThan(long.view.fittingSize.height, 150,
                             "The block's real alt text must reach the visible placeholder and wrap")
    }

    /// Compares two live renders at the same scale and OS, not stored snapshots. Pixel equality
    /// pins the visible alt text independently of accessibility labels; no cross-OS pixel baseline.
    func testInlinePlaceholderRendersAltTextAndEmptyFallback() async throws {
        for scheme in [ColorScheme.light, .dark] {
            for alt in ["Diagram unavailable here", ""] {
                let provider = PreviewImageProvider(loader: PreviewImageLoader(), skillDirectory: nil, colorScheme: scheme)
                let image = try await provider.image(with: URL(string: "https://preview.example/blocked.png")!, label: alt)
                let actual = ImageRenderer(content: image)
                actual.scale = 2
                let expected = ImageRenderer(content:
                    Label(alt.isEmpty ? "Image unavailable" : alt, systemImage: "photo")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 320).fixedSize(horizontal: false, vertical: true)
                        .environment(\.colorScheme, scheme))
                expected.scale = 2
                let rendered = try XCTUnwrap(actual.cgImage)
                let reference = try XCTUnwrap(expected.cgImage)
                assertVisible(rendered, "Inline placeholder in \(scheme), alt=\(alt)")
                assertVisible(reference, "Reference placeholder in \(scheme), alt=\(alt)")
                XCTAssertEqual(rendered.width, reference.width, alt)
                XCTAssertEqual(rendered.height, reference.height, alt)
                assertRenderedTextMatches(rendered, reference, "Visible inline alt text in \(scheme)")
            }
        }
    }

    private func imageFixture() throws -> (files: FileService, root: String) {
        let files = FileService()
        let root = files.realPath(at: NSTemporaryDirectory()) + "/preview-render-" + UUID().uuidString
        try files.createDirectory(at: root)
        try files.writeData(at: root + "/red.png", data: PreviewImageFixture.png())
        return (files, root)
    }

    private func imageHost(markdown: String, directory: String?, loader: PreviewImageLoading,
                           width: CGFloat = 640) -> (view: NSHostingView<AnyView>, window: NSWindow) {
        let view = NSHostingView(rootView: AnyView(SkillPreviewView(markdownBody: markdown, scrolls: false,
                                                                 skillDirectory: directory, imageLoader: loader)
            .frame(width: width)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded()
        window.display()
        return (view, window)
    }

    private func assertVisible(_ image: CGImage, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let bytes = rgba(image)
        XCTAssertTrue(stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 0 },
                      "Capture must contain visible pixels: \(message)", file: file, line: line)
    }

    /// Text antialiasing may vary by up to four per RGBA byte between live renders.
    private func assertRenderedTextMatches(
        _ actual: CGImage, _ reference: CGImage, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let actualBytes = rgba(actual)
        let referenceBytes = rgba(reference)
        XCTAssertEqual(actualBytes.count, referenceBytes.count, message, file: file, line: line)
        let maximumDifference = zip(actualBytes, referenceBytes).reduce(0) {
            max($0, abs(Int($1.0) - Int($1.1)))
        }
        XCTAssertLessThanOrEqual(maximumDifference, 4,
                                "Rendered text RGBA byte difference exceeds 4: \(message)", file: file, line: line)
    }

    private func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}

private final class RecordingPreviewImageLoader: PreviewImageLoading {
    struct Result {
        let url: URL
        let loaded: Bool
        let onMainThread: Bool
    }
    private let lock = NSLock()
    private var recorded: [Result] = []
    private let unreadableLeaf: String?

    init(unreadableLeaf: String? = nil) { self.unreadableLeaf = unreadableLeaf }

    var results: [Result] { lock.withLock { recorded } }

    func loadImage(at url: URL, skillDirectory: String?) throws -> CGImage {
        let onMainThread = Thread.isMainThread
        do {
            if url.lastPathComponent == unreadableLeaf { throw CocoaError(.fileReadNoPermission) }
            let image = try PreviewImageLoader().loadImage(at: url, skillDirectory: skillDirectory)
            lock.withLock { recorded.append(Result(url: url, loaded: true, onMainThread: onMainThread)) }
            return image
        } catch {
            lock.withLock { recorded.append(Result(url: url, loaded: false, onMainThread: onMainThread)) }
            throw error
        }
    }
}
