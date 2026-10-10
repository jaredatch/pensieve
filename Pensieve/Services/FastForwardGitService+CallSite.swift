import Foundation

/// Default source arguments belong to the caller; witnesses retain their existing behavior.
extension FastForwardGitService {
    func probeUsability(file: StaticString = #fileID, line: UInt = #line) throws -> GitUsability {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performProbeUsability()
        }
    }

    func remoteURL(at path: String,
                   file: StaticString = #fileID, line: UInt = #line) throws -> String? {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performRemoteURL(at: path)
        }
    }

    func isWorktreeClean(at path: String,
                         file: StaticString = #fileID, line: UInt = #line) -> Bool {
        GitThreadGuard.withCallSite(file: file, line: line) {
            performIsWorktreeClean(at: path)
        }
    }

    func fetch(at path: String, credential: GitCredential?,
               file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performFetch(at: path, credential: credential)
        }
    }

    func fastForwardOnly(at path: String, credential: GitCredential?,
                         file: StaticString = #fileID, line: UInt = #line) throws -> FastForwardResult {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performFastForwardOnly(at: path, credential: credential)
        }
    }
}
