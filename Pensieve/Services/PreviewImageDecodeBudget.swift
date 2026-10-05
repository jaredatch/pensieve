import Foundation
import CoreGraphics

protocol PreviewImageBudgeting: AnyObject {
    var isCancelled: Bool { get }
    func checkAvailable() throws
    func reserve(_ pixels: Int) throws
    func cancel()
    func load(_ work: @escaping () -> CGImage?) async -> CGImage?
}

/// Owned by one rendered document and shared by its block and inline providers. Serial dispatch
/// keeps compressed buffers bounded while awaiting callers suspend outside the cooperative pool.
/// Charges declared source pixels, including repeats and failed decodes, before ImageIO decodes.
/// NSLock `lock` protects all mutable state, making shared access safe.
final class PreviewImageDecodeBudget: PreviewImageBudgeting, @unchecked Sendable {
    static let maximumPixels = 64_000_000
    private let queue = DispatchQueue(label: "com.jaredatch.pensieve.preview-images", qos: .userInitiated)
    private let lock = NSLock()
    private var remainingPixels = maximumPixels
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func checkAvailable() throws {
        try lock.withLock {
            guard remainingPixels > 0 else { throw PreviewImageError.blocked }
        }
    }

    func reserve(_ pixels: Int) throws {
        try lock.withLock {
            guard pixels <= remainingPixels else { throw PreviewImageError.blocked }
            remainingPixels -= pixels
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }

    func load(_ work: @escaping () -> CGImage?) async -> CGImage? {
        let request = Request()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    let admitted = lock.withLock { !cancelled && request.start() }
                    continuation.resume(returning: admitted ? work() : nil)
                }
            }
        } onCancel: {
            request.cancel()
        }
    }

    /// Admission and cancellation meet under a short lock. A request admitted before cancellation
    /// is already running and may finish; a cancelled request never calls the synchronous loader.
    /// NSLock `lock` protects all mutable state, making shared access safe.
    private final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func start() -> Bool { lock.withLock { !cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }
}
