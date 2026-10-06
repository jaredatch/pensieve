import AppKit
import Observation
import SwiftUI
import XCTest
@testable import MarkdownUI
@testable import Pensieve

@MainActor
final class SkillPreviewQueueTests: XCTestCase {
    func testRetainedPreviewStateLoadsImagesAfterReappearing() async throws {
        let loader = try PausedPreviewImageLoader(pausesFirst: false)
        let state = PreviewTabState()
        let markdown = "![Retained](\(try embeddedURL().absoluteString))"
        let host = NSHostingView(rootView: PreviewTabHarness(state: state, markdown: markdown, loader: loader))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        await TestWait.until(failureMessage: "The preview must load on first appearance") { loader.finished == 1 }
        await TestWait.until(failureMessage: "The initial paragraph probe must report its document budget") {
            !state.appearingBudgets.isEmpty
        }
        let initialBudget = try XCTUnwrap(loader.documentBudget)
        XCTAssertTrue(state.appearingBudgets.first === initialBudget)
        state.selection = 1
        await TestWait.until(failureMessage: "Switching tabs must make the preview disappear") { state.disappearances == 1 }
        await TestWait.until(failureMessage: "The retained document must be cancelled while its tab is hidden") {
            initialBudget.isCancelled
        }
        state.appearingBudgets.removeAll()
        state.selection = 0
        await TestWait.until(failureMessage: "The retained preview must appear again") { state.appearances == 2 }
        await TestWait.until(failureMessage: "The reappearing paragraph probe must report its own budget") {
            !state.appearingBudgets.isEmpty
        }
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                             failureMessage: "Retained preview state must load after reappearing") {
            loader.finished >= 2
        }
        XCTAssertEqual(loader.finished, 2, "Reappearance must finish exactly one replacement load")
        XCTAssertEqual(loader.decoded.count, 2, "A reappearing preview must decode its image again")
        await TestWait.until(failureMessage: "The paragraph probe must report the replacement document budget") {
            state.appearingBudgets.last?.isCancelled == false
        }
        let reappearedBudget = try XCTUnwrap(state.appearingBudgets.last, "The reappeared view must report its own budget")
        XCTAssertFalse(reappearedBudget === initialBudget, "Reappearing must replace the cancelled initial document budget")
        XCTAssertTrue(reappearedBudget === loader.documentBudget,
                      "The loader must use the reappeared document's own budget")
        XCTAssertFalse(reappearedBudget.isCancelled, "The reappeared document's own budget must not be cancelled")
    }

    func testProductionProviderFactorySharesTheSuppliedDocumentBudget() async throws {
        let bytes = try PreviewImagePolicyFixtures.png(width: 1_000, height: 1_000)
        let url = try XCTUnwrap(URL(string: "data:image/png;base64," + bytes.base64EncodedString()))
        let pixel = try PreviewImageFixture.decodedPNG()
        let preview = SkillPreviewView(markdownBody: "", imageLoader: PreviewImageLoader(decode: { _ in pixel }))
        let budget = PreviewImageDecodeBudget()
        let block = preview.imageProvider(budget: budget, colorScheme: .light)
        let inline = preview.imageProvider(budget: budget, colorScheme: .light)
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
        defer { loader.release() }
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
        let submissions = PreviewSubmissionExecutor()
        let pending = submissions.loads(count: 16, provider: provider, url: url)
        await TestWait.until(failureMessage: "All cancellable requests must be queued behind the paused decode") {
            submissions.isQueued(count: 16)
        }
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
            // These requests deliberately outlive the view's structured block tasks. Only the
            // rendered document's cancellation can prevent their pending work from starting.
            let budget = try XCTUnwrap(loader.documentBudget)
            let provider = PreviewImageProvider(loader: loader, skillDirectory: nil, budget: budget)
            let submissions = PreviewSubmissionExecutor()
            let pending = submissions.loads(count: 8, provider: provider, url: try XCTUnwrap(URL(string: url)))
            await TestWait.until(failureMessage: "All independent requests must be queued behind the paused decode") {
                submissions.isQueued(count: 8)
            }
            host.rootView = rebuild
                ? AnyView(SkillPreviewView(markdownBody: "![New](\(url))", scrolls: false, imageLoader: loader))
                : AnyView(Text("Preview removed"))
            host.layoutSubtreeIfNeeded()
            await TestWait.until(failureMessage: "The replaced or removed document must cancel before its decode is released") {
                budget.isCancelled
            }
            loader.release()
            for task in pending {
                let image = await task.value
                XCTAssertNil(image, "Document cancellation must refuse requests that outlive its block tasks")
            }
            await TestWait.until(failureMessage: "The running decode may finish, and the new document must load") {
                loader.finished >= (rebuild ? 2 : 1)
            }
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
    private let pausesFirst: Bool
    private var capturedBudget: PreviewImageBudgeting?
    private var urls: [URL] = []
    private var completions = 0
    var decoded: [URL] { lock.withLock { urls } }
    var finished: Int { lock.withLock { completions } }
    var documentBudget: PreviewImageBudgeting? { lock.withLock { capturedBudget } }

    init(pausesFirst: Bool = true) throws {
        pixel = try PreviewImageFixture.decodedPNG()
        self.pausesFirst = pausesFirst
    }
    func release() { gate.signal() }

    func loadImage(at url: URL, skillDirectory: String?, budget: PreviewImageBudgeting?) throws -> CGImage {
        lock.withLock { capturedBudget = budget }
        defer { lock.withLock { completions += 1 } }
        return try PreviewImageLoader(decode: { [self] _ in
            let first = lock.withLock { urls.append(url); return urls.count == 1 }
            if first && pausesFirst { _ = gate.wait(timeout: .now() + TestWait.timeoutSeconds) }
            return pixel
        }).loadImage(at: url, skillDirectory: skillDirectory, budget: budget)
    }
}

@MainActor
@Observable
private final class PreviewTabState {
    var selection = 0
    var appearances = 0
    var disappearances = 0
    var appearingBudgets: [PreviewImageBudgeting] = []
}

private struct PreviewTabHarness: View {
    @Bindable var state: PreviewTabState
    let markdown: String
    let loader: PreviewImageLoading

    var body: some View {
        TabView(selection: $state.selection) {
            SkillPreviewView(markdownBody: markdown, scrolls: false, imageLoader: loader)
                .markdownBlockStyle(\.paragraph) { configuration in
                    PreviewBudgetAppearanceProbe(label: configuration.label, state: state)
                }
                .onAppear { state.appearances += 1 }
                .onDisappear { state.disappearances += 1 }
                .tabItem { Text("Preview") }.tag(0)
            Text("Other tab").tabItem { Text("Other") }.tag(1)
        }
    }
}

/// Reads the provider installed inside the rendered document. It preserves the paragraph label
/// and does not intercept loading.
private struct PreviewBudgetAppearanceProbe<Label: View>: View {
    @Environment(\.inlineImageProvider) private var provider
    let label: Label
    let state: PreviewTabState

    var body: some View {
        label.onAppear {
            guard let provider = provider as? PreviewImageProvider else {
                return XCTFail("The mounted document must install its production image provider")
            }
            state.appearingBudgets.append(provider.budget)
        }
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

/// Observes scheduling only on the modern XCTest host (CI uses macOS 26). The preferred executor
/// runs provider tasks until they suspend; after every request starts and no runnable job or
/// completed request remains, their only suspension is the real budget's queued continuation.
/// It never replaces the budget, its queue, cancellation, reads or decoding.
private final class PreviewSubmissionExecutor: TaskExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "PreviewSubmissionExecutor")
    private let lock = NSLock()
    private var runnable = 0
    private var started = 0
    private var completed = 0

    func isQueued(count: Int) -> Bool {
        lock.withLock { started == count && runnable == 0 && completed == 0 }
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        lock.withLock { runnable += 1 }
        queue.async {
            job.runSynchronously(on: self.asUnownedTaskExecutor())
            self.lock.withLock { self.runnable -= 1 }
        }
    }

    func loads(count: Int, provider: PreviewImageProvider, url: URL) -> [Task<CGImage?, Never>] {
        (0..<count).map { _ in
            Task.detached(executorPreference: self) {
                self.lock.withLock { self.started += 1 }
                defer { self.lock.withLock { self.completed += 1 } }
                return await provider.loadImage(url: url)
            }
        }
    }
}
