import Darwin
import Foundation
import os

/// The common subprocess boundary enforces the same thread rule for app, daemon and tests.
enum GitThreadGuard {
    static func check(file: StaticString, line: UInt) {
        guard Thread.isMainThread else { return }
        let stack = Thread.callStackSymbols.map(symbolicate)
        let functions = stack.compactMap { $0.function }
        let boundary = functions.firstIndex(where: isGitImplementation) ?? functions.startIndex
        let caller = functions[boundary...].first { !isGitImplementation($0) } ?? "\(file):\(line)"
        let detail = "Git called on the main thread at \(caller) (git boundary: \(file):\(line))\n"
            + stack.map { $0.text }.joined(separator: "\n")
        #if DEBUG
        preconditionFailure(detail)
        #else
        Logger(subsystem: "com.jaredatch.pensieve", category: "git").fault("\(detail, privacy: .public)")
        #endif
    }

    private static func isGitImplementation(_ function: String) -> Bool {
        // Ignore argument types: an app caller can itself accept a GitServiceProtocol.
        let declaration = function.replacingOccurrences(of: #"\(extension in [^)]+\):"#,
                                                         with: "", options: .regularExpression)
            .prefix { $0 != "(" }
        return [".GitThreadGuard.", ".GitService.", ".GitServiceProtocol."].contains {
            declaration.contains($0)
        }
    }

    private static func symbolicate(_ frame: String) -> (text: String, function: String?) {
        guard let demangle,
              let mangled = frame.split(separator: " ").first(where: {
                  $0.hasPrefix("$s") || $0.hasPrefix("_$s")
              }) else { return (frame, nil) }
        let name = String(mangled)
        guard let decoded = name.withCString({ demangle($0, name.utf8.count, nil, nil, 0) }) else {
            return (frame, nil)
        }
        defer { free(decoded) }
        let function = String(cString: decoded)
        return (frame.replacingOccurrences(of: name, with: function), function)
    }

    // Swift's runtime C demangler returns a malloc-owned name when no output buffer is supplied.
    private typealias Demangler = @convention(c) (
        UnsafePointer<CChar>, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
    ) -> UnsafeMutablePointer<CChar>?

    private static let demangle: Demangler? = {
        // Darwin's RTLD_DEFAULT is ((void *) -2); Swift cannot import that pointer macro.
        guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil }
        return unsafeBitCast(address, to: Demangler.self)
    }()
}
