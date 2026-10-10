import Foundation

/// The orchestration call site opts only a read-only phase into cancellation. Writing phases
/// retain the default even when their task is cancelled, so they finish the transaction.
enum GitCancellation {
    @TaskLocal static var isReadOnly = false

    static func check() throws {
        if isReadOnly { try Task.checkCancellation() }
    }
}
