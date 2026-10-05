import Foundation
@testable import Pensieve

/// A lock protects the gate and counts. The only blocked operation is the injected directory
/// lookup; real disk operations remain in FileService. A finite wait also bounds a broken implementation.
final class ProjectFolderBlockingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var blockedPath: String?
    private var counts: [String: Int] = [:]
    func block(_ path: String?) { lock.withLock { blockedPath = path } }
    func count(_ path: String) -> Int { lock.withLock { counts[path, default: 0] } }
    func unblock() { block(nil); release.signal() }
    func probe(_ path: String) throws -> Bool {
        let blocked = lock.withLock {
            counts[path, default: 0] += 1
            return blockedPath == path
        }
        if blocked { _ = release.wait(timeout: .now() + 4) }
        return try FileService.probeDirectory(path)
    }
}
