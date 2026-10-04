import Foundation
@testable import Pensieve

/// Records measurements only at an explicit path injected by the test driver. Without that
/// environment setting it performs no I/O, and it never resolves a default user-state path.
enum PreviewResourceTestEvidence {
    static func record(_ metric: String, message: String) throws {
        let key = "PENSIEVE_PREVIEW_" + metric.uppercased() + "_METRICS_PATH"
        guard let path = ProcessInfo.processInfo.environment[key] else { return }
        try FileService().writeFile(at: path, content: message + "\n")
    }
}
