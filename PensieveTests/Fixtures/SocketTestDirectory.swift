import Foundation
@testable import Pensieve

/// Socket addresses have a 104-byte kernel limit. The stage runner supplies its external TMPDIR;
/// ordinary Xcode runs use the documented short system-temp exception, never real App Support.
final class SocketTestDirectory {
    let path: String
    let files = FileService()

    init() throws {
        let base = ProcessInfo.processInfo.environment["PENSIEVE_SOCKET_TEST_ROOT"] ?? TestTemporaryDirectory.systemPath
        path = (base as NSString).appendingPathComponent("s-" + UUID().uuidString.prefix(8))
        try files.createDirectory(at: path)
    }

    deinit { try? files.deleteDirectory(at: path) }
}
