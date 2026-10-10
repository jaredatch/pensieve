import Foundation

/// Default source arguments belong to the caller; witnesses retain their existing behavior.
extension SkillInstallGitServing {
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

    func currentBranch(at path: String,
                       file: StaticString = #fileID, line: UInt = #line) throws -> String {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performCurrentBranch(at: path)
        }
    }

    func treeHash(at repositoryPath: String, path: String,
                  file: StaticString = #fileID, line: UInt = #line) throws -> String {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performTreeHash(at: repositoryPath, path: path)
        }
    }
}
