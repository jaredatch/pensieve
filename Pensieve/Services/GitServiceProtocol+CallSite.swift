import Foundation

// Source defaults capture the caller; typed references dispatch public protocol witnesses.
extension GitServiceProtocol {
    func initRepository(at path: String,
                        file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String) throws -> Void = self.initRepository
            return try operation(path)
        }
    }

    func setRemote(_ url: String, at path: String,
                   file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String, String) throws -> Void = self.setRemote
            return try operation(url, path)
        }
    }

    func removeRemote(at path: String,
                      file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String) throws -> Void = self.removeRemote
            return try operation(path)
        }
    }

    func configuredRemoteURL(at path: String,
                             file: StaticString = #fileID, line: UInt = #line) throws -> String? {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String) throws -> String? = self.configuredRemoteURL
            return try operation(path)
        }
    }

    func clone(remote: String, into path: String, credential: GitCredential?,
               file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String, String, GitCredential?) throws -> Void = self.clone
            return try operation(remote, path, credential)
        }
    }

    func remoteHasCommits(remote: String, credential: GitCredential?,
                          file: StaticString = #fileID, line: UInt = #line) -> Bool {
        GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String, GitCredential?) -> Bool = self.remoteHasCommits
            return operation(remote, credential)
        }
    }

    func remoteReferences(remote: String, credential: GitCredential?,
                          file: StaticString = #fileID, line: UInt = #line) throws -> GitRemoteReferences {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String, GitCredential?) throws -> GitRemoteReferences = self.remoteReferences
            return try operation(remote, credential)
        }
    }

    func checkoutUnbornBranch(_ branch: String, at path: String,
                              file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String, String) throws -> Void = self.checkoutUnbornBranch
            return try operation(branch, path)
        }
    }

    func fetchBranch(_ branch: String, at path: String, credential: GitCredential?,
                     file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String, String, GitCredential?) throws -> Void = self.fetchBranch
            return try operation(branch, path, credential)
        }
    }

    func materializeFromFetchHead(at path: String,
                                  file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String) throws -> Void = self.materializeFromFetchHead
            return try operation(path)
        }
    }

    func bornBranch(_ branch: String, at path: String,
                    file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String, String) throws -> Void = self.bornBranch
            return try operation(branch, path)
        }
    }

    func setUpstream(branch: String, at path: String,
                     file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String, String) throws -> Void = self.setUpstream
            return try operation(branch, path)
        }
    }

    func hasLocalBranches(at path: String,
                          file: StaticString = #fileID, line: UInt = #line) throws -> Bool {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String) throws -> Bool = self.hasLocalBranches
            return try operation(path)
        }
    }

    func hasRemoteTrackingBranch(_ branch: String, at path: String,
                                 file: StaticString = #fileID, line: UInt = #line) -> Bool {
        GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String, String) -> Bool = self.hasRemoteTrackingBranch
            return operation(branch, path)
        }
    }

    func hasRemoteOriginConfigured(at path: String,
                                   file: StaticString = #fileID, line: UInt = #line) throws -> Bool {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String) throws -> Bool = self.hasRemoteOriginConfigured
            return try operation(path)
        }
    }

    @discardableResult
    func stageAllAndCommit(at path: String, message: String,
                           file: StaticString = #fileID, line: UInt = #line) throws -> Bool {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String, String) throws -> Bool = self.stageAllAndCommit
            return try operation(path, message)
        }
    }

    func preflightStoreUpdate(at path: String, credential: GitCredential?,
                              file: StaticString = #fileID, line: UInt = #line) throws -> FetchedStoreRevision? {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String, GitCredential?) throws -> FetchedStoreRevision? = self.preflightStoreUpdate
            return try operation(path, credential)
        }
    }

    func pullRebase(at path: String, credential: GitCredential?,
                    file: StaticString = #fileID, line: UInt = #line) throws -> PullResult {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String, GitCredential?) throws -> PullResult = self.pullRebase
            return try operation(path, credential)
        }
    }

    func pullRebase(at path: String, fetchedRevision: FetchedStoreRevision,
                    file: StaticString = #fileID, line: UInt = #line) throws -> PullResult {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String, FetchedStoreRevision) throws -> PullResult = self.pullRebase
            return try operation(path, fetchedRevision)
        }
    }

    func push(at path: String, credential: GitCredential?,
              file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String, GitCredential?) throws -> Void = self.push
            return try operation(path, credential)
        }
    }

    func abortRebase(at path: String,
                     file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String) throws -> Void = self.abortRebase
            return try operation(path)
        }
    }

    func abortRebase(at path: String, refusedFolder: String,
                     file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String, String) throws -> Void = self.abortRebase
            return try operation(path, refusedFolder)
        }
    }

    func conflictedFiles(at path: String,
                         file: StaticString = #fileID, line: UInt = #line) throws -> [String] {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String) throws -> [String] = self.conflictedFiles
            return try operation(path)
        }
    }

    func blob(atStage stage: Int, path: String, in workingDir: String,
              file: StaticString = #fileID, line: UInt = #line) throws -> Data? {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (Int, String, String) throws -> Data? = self.blob
            return try operation(stage, path, workingDir)
        }
    }

    func conflictEntry(atStage stage: Int, path: String, in workingDir: String,
                       file: StaticString = #fileID, line: UInt = #line) throws -> ConflictEntry? {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (Int, String, String) throws -> ConflictEntry? = self.conflictEntry
            return try operation(stage, path, workingDir)
        }
    }

    func restoreConflictEntry(_ entry: ConflictEntry, stage: Int, path: String, at root: String,
                              file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (ConflictEntry, Int, String, String) throws -> Void = self.restoreConflictEntry
            return try operation(entry, stage, path, root)
        }
    }

    func retireConflictPath(_ path: String, at root: String,
                            file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String, String) throws -> Void = self.retireConflictPath
            return try operation(path, root)
        }
    }

    func removeConflictEntryFromIndex(_ path: String, at root: String,
                                      file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String, String) throws -> Void = self.removeConflictEntryFromIndex
            return try operation(path, root)
        }
    }

    func continueRebase(at path: String,
                        file: StaticString = #fileID, line: UInt = #line) throws -> PullResult {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String) throws -> PullResult = self.continueRebase
            return try operation(path)
        }
    }

    func skipRebase(at path: String,
                    file: StaticString = #fileID, line: UInt = #line) throws -> PullResult {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String) throws -> PullResult = self.skipRebase
            return try operation(path)
        }
    }

    func stagePath(_ path: String, at root: String,
                   file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String, String) throws -> Void = self.stagePath
            return try operation(path, root)
        }
    }

    func collapseToSingleCommit(at root: String, message: String, credential: GitCredential?,
                                fetchedRevision: FetchedStoreRevision? = nil,
                                file: StaticString = #fileID, line: UInt = #line) throws -> Bool {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String, String, GitCredential?, FetchedStoreRevision?) throws -> Bool = self.collapseToSingleCommit
            return try operation(root, message, credential, fetchedRevision)
        }
    }

    func hasCommitsToPush(at path: String,
                          file: StaticString = #fileID, line: UInt = #line) throws -> Bool {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String) throws -> Bool = self.hasCommitsToPush
            return try operation(path)
        }
    }

    func log(forPath path: String, at workingDir: String, limit: Int,
             file: StaticString = #fileID, line: UInt = #line) -> [GitCommit] {
        GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String, String, Int) -> [GitCommit] = self.log
            return operation(path, workingDir, limit)
        }
    }

    func show(sha: String, path: String, at workingDir: String,
              file: StaticString = #fileID, line: UInt = #line) -> String? {
        GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String, String, String) -> String? = self.show
            return operation(sha, path, workingDir)
        }
    }
}
