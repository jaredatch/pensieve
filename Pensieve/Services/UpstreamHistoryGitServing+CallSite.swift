import Foundation

// Source defaults capture the caller; typed references dispatch public protocol witnesses.
extension UpstreamHistoryGitServing {
    func upstreamHistory(_ request: UpstreamHistoryGitRequest,
                         file: StaticString = #fileID, line: UInt = #line) throws -> UpstreamHistoryGitSnapshot {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (UpstreamHistoryGitRequest) throws -> UpstreamHistoryGitSnapshot = self.upstreamHistory
            return try operation(request)
        }
    }
}
