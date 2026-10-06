import AppKit
import ImageIO
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class SkillPreviewBudgetTests: XCTestCase {
    func testRepeatedBlockImagesShareOneDecodeBudgetAndShowPlaceholders() async throws {
        try await assertBudget(shape: .blocks)
    }

    func testRepeatedInlineQueryImagesShareOneDecodeBudgetAndShowPlaceholders() async throws {
        try await assertBudget(shape: .inline)
    }

    func testBlockEmbeddedAndInlineLocalImagesShareBudgetAndRebuildResetsIt() async throws {
        try await assertBudget(shape: .mixed, rebuild: true)
    }

    private enum Shape { case blocks, inline, mixed }

    private func assertBudget(shape: Shape, rebuild: Bool = false) async throws {
        let files = FileService()
        let root = files.realPath(at: TestTemporaryDirectory.path) + "/PreviewBudget-" + UUID().uuidString
        defer { try? files.deleteDirectory(at: root) }
        let bytes = try PreviewImagePolicyFixtures.png(width: 1_000, height: 1_000)
        try files.writeData(at: root + "/small.png", data: bytes)
        let embedded = "data:image/png;base64," + bytes.base64EncodedString()
        let references = (0..<70).map { index -> String in
            let url = shape == .mixed && index < 35 ? embedded : "small.png?\(index)"
            return "![Budget image \(index)](\(url))"
        }
        let markdown: String
        switch shape {
        case .blocks: markdown = Array(repeating: "![Budget image](small.png)", count: 70).joined(separator: "\n\n")
        case .inline: markdown = "Before " + references.joined(separator: " ") + " after."
        case .mixed:
            markdown = references.prefix(35).joined(separator: "\n\n") + "\n\nBefore "
                + references.suffix(35).joined(separator: " ") + " after."
        }
        let recorder = try BudgetImageRecorder()
        let host = NSHostingView(rootView: SkillPreviewView(markdownBody: markdown, scrolls: false,
                                                           skillDirectory: root, imageLoader: recorder))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        await TestWait.until(failureMessage: "Every repeated image must finish or return its placeholder") {
            recorder.attempts == 70
        }
        XCTAssertEqual(recorder.decodedPixels, 64_000_000, "The mounted preview must stop before the sixty-fifth decode")
        XCTAssertEqual(recorder.successes, 64)
        XCTAssertEqual(recorder.attempts - recorder.successes, 6, "Over-budget images must take the provider's placeholder path")
        if shape == .mixed {
            XCTAssertEqual(recorder.embeddedAttempts, 35)
            XCTAssertEqual(recorder.localAttempts, 35)
        }
        if rebuild {
            host.rootView = SkillPreviewView(markdownBody: markdown + "\n\nA new rendered document.", scrolls: false,
                                             skillDirectory: root, imageLoader: recorder)
            host.layoutSubtreeIfNeeded()
            await TestWait.until(failureMessage: "A rebuilt document must receive a fresh decode budget") {
                recorder.attempts == 140
            }
            XCTAssertEqual(recorder.decodedPixels, 128_000_000)
            XCTAssertEqual(recorder.successes, 128)
            XCTAssertEqual(recorder.attempts - recorder.successes, 12)
        }
    }
}

/// Uses real bounded reads and ImageIO metadata from complete compressed fixtures. The decoder
/// records declared pixels but returns a tiny bitmap, so an intentionally unbounded red stays cheap.
/// It records every provider refusal as a placeholder path and never substitutes filesystem admission.
private final class BudgetImageRecorder: PreviewImageLoading {
    private let lock = NSLock()
    private let pixel: CGImage
    private var pixels = 0
    private var loaded = 0
    private var local = 0
    private var embedded = 0
    var decodedPixels: Int { lock.withLock { pixels } }
    var successes: Int { lock.withLock { loaded } }
    var attempts: Int { lock.withLock { local + embedded } }
    var localAttempts: Int { lock.withLock { local } }
    var embeddedAttempts: Int { lock.withLock { embedded } }

    init() throws { pixel = try PreviewImageFixture.decodedPNG() }

    func loadImage(at url: URL, skillDirectory: String?, budget: PreviewImageBudgeting?) throws -> CGImage {
        defer { lock.withLock { if url.scheme == "data" { embedded += 1 } else { local += 1 } } }
        let loader = PreviewImageLoader(decode: { [self] source in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            lock.withLock { pixels += width * height }
            return pixel
        })
        let image = try loader.loadImage(at: url, skillDirectory: skillDirectory, budget: budget)
        lock.withLock { loaded += 1 }
        return image
    }
}
