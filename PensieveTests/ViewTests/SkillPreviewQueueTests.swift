import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class SkillPreviewQueueTests: XCTestCase {
    func testProductionProviderFactorySharesTheSuppliedDocumentBudget() async throws {
        let bytes = try PreviewImagePolicyFixtures.png(width: 1_000, height: 1_000)
        let url = try XCTUnwrap(URL(string: "data:image/png;base64," + bytes.base64EncodedString()))
        let pixel = try PreviewImageFixture.decodedPNG()
        let preview = SkillPreviewView(markdownBody: "", imageLoader: PreviewImageLoader(decode: { _ in pixel }))
        let budget = PreviewImageDecodeBudget()
        let block = preview.imageProvider(budget: budget)
        let inline = preview.imageProvider(budget: budget)
        XCTAssertTrue(block.budget === budget)
        XCTAssertTrue(inline.budget === budget)
        for _ in 0..<64 {
            let image = await block.loadImage(url: url)
            XCTAssertNotNil(image)
        }
        let refused = await inline.loadImage(url: url)
        XCTAssertNil(refused, "The production factory must share the supplied document budget")
    }

    func testQueuedImageLoadsLeaveCooperativeThreadsAvailable() async throws {
        let loader = try PausedPreviewImageLoader()
        let provider = PreviewImageProvider(loader: loader, skillDirectory: nil, budget: PreviewImageDecodeBudget())
        let url = try embeddedURL()
        let progress = PreviewQueueProgress()
        let tasks = (0..<70).map { _ in Task.detached { await provider.loadImage(url: url) } }
        // Dispatch timers must release the decoder even when the concurrency pool is exhausted.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            Task.detached { progress.noteUnrelatedWork() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            progress.observeBeforeRelease(decodes: loader.decoded.count)
            loader.release()
        }
        for task in tasks { _ = await task.value }
        XCTAssertTrue(progress.completedBeforeRelease,
                      "Unrelated async work must finish while the image decode and its queue are paused")
        XCTAssertEqual(progress.decodesBeforeRelease, 1, "Only one document decode may run at a time")
        XCTAssertEqual(loader.decoded.count, 70)
    }

    func testCancelledQueuedImageLoadsNeverReachTheDecoder() async throws {
        let loader = try PausedPreviewImageLoader()
        defer { loader.release() }
        let provider = PreviewImageProvider(loader: loader, skillDirectory: nil, budget: PreviewImageDecodeBudget())
        let url = try embeddedURL()
        let first = Task { await provider.loadImage(url: url) }
        await TestWait.until(failureMessage: "The first decode must start") { loader.decoded.count == 1 }
        let pending = (0..<16).map { _ in Task { await provider.loadImage(url: url) } }
        try await Task.sleep(for: .milliseconds(100))
        pending.forEach { $0.cancel() }
        loader.release()
        let initialImage = await first.value
        XCTAssertNotNil(initialImage)
        for task in pending {
            let image = await task.value
            XCTAssertNil(image, "A cancelled pending load must return without decoding")
        }
        XCTAssertEqual(loader.decoded.count, 1, "Only the decode already under way may finish")
    }

    func testRebuiltAndRemovedDocumentsCancelTheirPendingImageLoads() async throws {
        for rebuild in [true, false] {
            let loader = try PausedPreviewImageLoader()
            defer { loader.release() }
            let url = try embeddedURL().absoluteString
            let old = (0..<8).map { "![Old \($0)](\(url))" }.joined(separator: "\n\n")
            let host = NSHostingView(rootView: AnyView(SkillPreviewView(markdownBody: old, scrolls: false,
                                                                       imageLoader: loader)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            await TestWait.until(failureMessage: "The old document must start its first decode") {
                loader.decoded.count == 1
            }
            host.rootView = rebuild
                ? AnyView(SkillPreviewView(markdownBody: "![New](\(url))", scrolls: false, imageLoader: loader))
                : AnyView(Text("Preview removed"))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            loader.release()
            await TestWait.until(failureMessage: "The running decode may finish, and the new document must load") {
                loader.finished >= (rebuild ? 2 : 1)
            }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(loader.decoded.count, rebuild ? 2 : 1,
                           "Replacing or removing a document must discard its pending decodes")
        }
    }

    private func embeddedURL() throws -> URL {
        try XCTUnwrap(URL(string: "data:image/png;base64," + PreviewImageFixture.png().base64EncodedString()))
    }
}

/// Intercepts only image decoding after the production loader has validated embedded bytes and
/// reserved pixels. Pauses its first decode; a bounded semaphore prevents a failed test hanging.
/// It never replaces filesystem admission, metadata checks, or budget accounting.
private final class PausedPreviewImageLoader: PreviewImageLoading {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let pixel: CGImage
    private var urls: [URL] = []
    private var completions = 0
    var decoded: [URL] { lock.withLock { urls } }
    var finished: Int { lock.withLock { completions } }

    init() throws { pixel = try PreviewImageFixture.decodedPNG() }
    func release() { gate.signal() }

    func loadImage(at url: URL, skillDirectory: String?, budget: PreviewImageBudgeting?) throws -> CGImage {
        defer { lock.withLock { completions += 1 } }
        return try PreviewImageLoader(decode: { [self] _ in
            let first = lock.withLock { urls.append(url); return urls.count == 1 }
            if first { _ = gate.wait(timeout: .now() + 10) }
            return pixel
        }).loadImage(at: url, skillDirectory: skillDirectory, budget: budget)
    }
}

private final class PreviewQueueProgress {
    private let lock = NSLock()
    private var completed = false
    private var observed = false
    private var decodes = 0
    var completedBeforeRelease: Bool { lock.withLock { observed } }
    var decodesBeforeRelease: Int { lock.withLock { decodes } }
    func noteUnrelatedWork() { lock.withLock { completed = true } }
    func observeBeforeRelease(decodes: Int) { lock.withLock { observed = completed; self.decodes = decodes } }
}
