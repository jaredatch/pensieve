import XCTest
import SwiftUI
@testable import Pensieve

final class PreviewImageBudgetTests: XCTestCase {
    @MainActor
    func testFactoryAndProviderAcceptBudgetProtocolWithExplicitDarkScheme() async throws {
        let budget = RefusingPreviewImageBudget()
        let preview = SkillPreviewView(markdownBody: "")
        let provider = preview.imageProvider(budget: budget, colorScheme: .dark)
        XCTAssertTrue(provider.budget === budget, "The factory must retain the injected protocol implementation")
        XCTAssertEqual(provider.colorScheme, .dark)
        let image = await provider.loadImage(url: URL(string: "data:image/png;base64,unused"))
        XCTAssertNil(image)
        XCTAssertEqual(budget.loads, 1, "The provider must delegate loading to the injected budget protocol")
    }

    func testSpentBudgetRefusesBeforeLocalReadOrEmbeddedByteDecode() throws {
        let files = PreviewImageFileSpy()
        let root = files.files.realPath(at: TestTemporaryDirectory.path) + "/SpentBudget-" + UUID().uuidString
        defer { try? files.files.deleteDirectory(at: root) }
        try files.files.writeData(at: root + "/image.png", data: PreviewImageFixture.png())
        let budget = PreviewImageDecodeBudget()
        try budget.reserve(PreviewImageDecodeBudget.maximumPixels)
        var decoded = false
        let loader = PreviewImageLoader(fileService: files, decode: { _ in decoded = true; return nil })
        let local = try XCTUnwrap(URL(string: "image.png"))
        let invalidEmbedded = try XCTUnwrap(URL(string: "data:image/png;base64,invalid-payload"))
        for url in [local, invalidEmbedded] {
            XCTAssertThrowsError(try loader.loadImage(at: url, skillDirectory: root, budget: budget)) { error in
                guard case PreviewImageError.blocked = error else {
                    return XCTFail("A spent budget must refuse before inspecting bytes: \(error)")
                }
            }
        }
        XCTAssertTrue(files.reads.isEmpty, "A spent budget must refuse before any contained file read")
        XCTAssertFalse(decoded, "A spent budget must never reach the image decoder")
    }
}

/// Intercepts the budget protocol's scheduling seam and refuses its work without invoking the
/// loader. Records delegation only; it does not model file admission, decoding or pixel accounting.
private final class RefusingPreviewImageBudget: PreviewImageBudgeting {
    private let lock = NSLock()
    private var requests = 0
    private var cancelled = false
    var loads: Int { lock.withLock { requests } }
    var isCancelled: Bool { lock.withLock { cancelled } }
    func checkAvailable() throws { throw PreviewImageError.blocked }
    func reserve(_ pixels: Int) throws { throw PreviewImageError.blocked }
    func cancel() { lock.withLock { cancelled = true } }
    func load(_ work: @escaping () -> CGImage?) async -> CGImage? {
        lock.withLock { requests += 1 }
        return nil
    }
}
