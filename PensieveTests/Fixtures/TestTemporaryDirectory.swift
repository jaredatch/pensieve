import Foundation
@testable import Pensieve

/// Derives fixture paths under test.sh's per-run root, containing sibling lock files too.
/// Only existing directories are accepted. Xcode runs fall back to the system temp directory.
/// systemPath is the only escape from the per-run root; callers must document why and clean up their fixtures.
enum TestTemporaryDirectory {
    static var path: String {
        guard let root = ProcessInfo.processInfo.environment["PENSIEVE_TEST_TEMP_ROOT"],
              FileService().directoryExists(at: root) else { return systemPath }
        return root.hasSuffix("/") ? root : root + "/"
    }

    static var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    static var systemPath: String {
        NSTemporaryDirectory()
    }
}
