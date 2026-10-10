import Foundation
import os

/// The common subprocess boundary enforces the same thread rule for app, daemon and tests.
enum GitThreadGuard {
    static func check(file: StaticString, line: UInt) {
        guard Thread.isMainThread else { return }
        let detail = "Git called on the main thread at \(file):\(line)\n"
            + Thread.callStackSymbols.joined(separator: "\n")
        #if DEBUG
        preconditionFailure(detail)
        #else
        Logger(subsystem: "com.jaredatch.pensieve", category: "git").fault("\(detail, privacy: .public)")
        #endif
    }
}
