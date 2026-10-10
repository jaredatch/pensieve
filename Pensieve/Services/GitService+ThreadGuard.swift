import Foundation
import os

enum GitThreadGuard {
    private struct CallSite {
        let file: StaticString
        let line: UInt
    }

    @TaskLocal private static var callSite: CallSite?

    /// Nested helpers retain the first entry's source, including synchronous closure calls.
    static func withCallSite<T>(file: StaticString, line: UInt, _ operation: () throws -> T) rethrows -> T {
        if callSite != nil { return try operation() }
        return try $callSite.withValue(CallSite(file: file, line: line), operation: operation)
    }

    static func check(file: StaticString, line: UInt) {
        guard Thread.isMainThread else { return }
        let source = callSite ?? CallSite(file: file, line: line)
        let detail = "Git called on the main thread at \(source.file):\(source.line)\n"
            + Thread.callStackSymbols.joined(separator: "\n")
        #if DEBUG
        preconditionFailure(detail)
        #else
        Logger(subsystem: "com.jaredatch.pensieve", category: "git").fault("\(detail, privacy: .public)")
        #endif
    }
}
