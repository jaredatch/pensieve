import Foundation

/// Default source arguments belong to the caller; witnesses retain their existing behavior.
extension UpdateCheckGitServing {
    func probeUsability(file: StaticString = #fileID, line: UInt = #line) throws -> GitUsability {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performProbeUsability()
        }
    }

    func remoteHead(remote: String, ref: String,
                    credential: GitCredential?,
                    file: StaticString = #fileID, line: UInt = #line) throws -> String? {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performRemoteHead(remote: remote, ref: ref, credential: credential)
        }
    }

    func cloneShallow(remote: String, branch: String?, into path: String,
                      credential: GitCredential?,
                      file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performCloneShallow(remote: remote, branch: branch, into: path, credential: credential)
        }
    }

    func commitSHA(at path: String,
                   file: StaticString = #fileID, line: UInt = #line) throws -> String {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performCommitSHA(at: path)
        }
    }

    func commitDate(at repositoryPath: String,
                    file: StaticString = #fileID, line: UInt = #line) throws -> Date {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performCommitDate(at: repositoryPath)
        }
    }

    func treeHash(at repositoryPath: String, path: String,
                  file: StaticString = #fileID, line: UInt = #line) throws -> String {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performTreeHash(at: repositoryPath, path: path)
        }
    }
}
