import Foundation

/// Default source arguments belong to the caller; witnesses retain their existing behavior.
extension UpstreamHistoryGitServing {
    func upstreamHistory(_ request: UpstreamHistoryGitRequest,
                         file: StaticString = #fileID, line: UInt = #line) throws -> UpstreamHistoryGitSnapshot {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performUpstreamHistory(request)
        }
    }

    func remoteHead(remote: String, ref: String, credential: GitCredential?,
                    file: StaticString = #fileID, line: UInt = #line) throws -> String? {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performRemoteHead(remote: remote, ref: ref, credential: credential)
        }
    }
}
