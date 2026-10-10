import Foundation

/// Default source arguments belong to the caller; witnesses retain their existing behavior.
extension GitServiceProtocol {
    func probeUsability(file: StaticString = #fileID, line: UInt = #line) throws -> GitUsability {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performProbeUsability()
        }
    }

    func initRepository(at path: String,
                        file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performInitRepository(at: path)
        }
    }

    func setRemote(_ url: String, at path: String,
                   file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performSetRemote(url, at: path)
        }
    }

    func removeRemote(at path: String,
                      file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performRemoveRemote(at: path)
        }
    }

    func configuredRemoteURL(at path: String,
                             file: StaticString = #fileID, line: UInt = #line) throws -> String? {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performConfiguredRemoteURL(at: path)
        }
    }

    func remoteURL(at path: String,
                   file: StaticString = #fileID, line: UInt = #line) throws -> String? {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performRemoteURL(at: path)
        }
    }

    func clone(remote: String, into path: String, credential: GitCredential?,
               file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performClone(remote: remote, into: path, credential: credential)
        }
    }

    func remoteHasCommits(remote: String, credential: GitCredential?,
                          file: StaticString = #fileID, line: UInt = #line) -> Bool {
        GitThreadGuard.withCallSite(file: file, line: line) {
            performRemoteHasCommits(remote: remote, credential: credential)
        }
    }

    func remoteDefaultBranch(remote: String, credential: GitCredential?,
                             file: StaticString = #fileID, line: UInt = #line) throws -> String? {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performRemoteDefaultBranch(remote: remote, credential: credential)
        }
    }

    func remoteBranches(remote: String, credential: GitCredential?,
                        file: StaticString = #fileID, line: UInt = #line) throws -> [String] {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performRemoteBranches(remote: remote, credential: credential)
        }
    }

    func checkoutUnbornBranch(_ branch: String, at path: String,
                              file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performCheckoutUnbornBranch(branch, at: path)
        }
    }

    func fetchBranch(_ branch: String, at path: String, credential: GitCredential?,
                     file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performFetchBranch(branch, at: path, credential: credential)
        }
    }

    func materializeFromFetchHead(at path: String,
                                  file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performMaterializeFromFetchHead(at: path)
        }
    }

    func bornBranch(_ branch: String, at path: String,
                    file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performBornBranch(branch, at: path)
        }
    }

    func setUpstream(branch: String, at path: String,
                     file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performSetUpstream(branch: branch, at: path)
        }
    }

    func hasLocalBranches(at path: String,
                          file: StaticString = #fileID, line: UInt = #line) throws -> Bool {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performHasLocalBranches(at: path)
        }
    }

    func hasRemoteTrackingBranch(_ branch: String, at path: String,
                                 file: StaticString = #fileID, line: UInt = #line) -> Bool {
        GitThreadGuard.withCallSite(file: file, line: line) {
            performHasRemoteTrackingBranch(branch, at: path)
        }
    }

    func hasRemoteOriginConfigured(at path: String,
                                   file: StaticString = #fileID, line: UInt = #line) throws -> Bool {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performHasRemoteOriginConfigured(at: path)
        }
    }

    @discardableResult
    func stageAllAndCommit(at path: String, message: String,
                           file: StaticString = #fileID, line: UInt = #line) throws -> Bool {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performStageAllAndCommit(at: path, message: message)
        }
    }

    func preflightStoreUpdate(at path: String, credential: GitCredential?,
                              file: StaticString = #fileID, line: UInt = #line) throws -> FetchedStoreRevision? {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performPreflightStoreUpdate(at: path, credential: credential)
        }
    }

    func pullRebase(at path: String, credential: GitCredential?,
                    file: StaticString = #fileID, line: UInt = #line) throws -> PullResult {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performPullRebase(at: path, credential: credential)
        }
    }

    func pullRebase(at path: String, fetchedRevision: FetchedStoreRevision,
                    file: StaticString = #fileID, line: UInt = #line) throws -> PullResult {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performPullRebase(at: path, fetchedRevision: fetchedRevision)
        }
    }

    func push(at path: String, credential: GitCredential?,
              file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performPush(at: path, credential: credential)
        }
    }

    func abortRebase(at path: String,
                     file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performAbortRebase(at: path)
        }
    }

    func conflictedFiles(at path: String,
                         file: StaticString = #fileID, line: UInt = #line) throws -> [String] {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performConflictedFiles(at: path)
        }
    }

    func blob(atStage stage: Int, path: String, in workingDir: String,
              file: StaticString = #fileID, line: UInt = #line) throws -> Data? {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performBlob(atStage: stage, path: path, in: workingDir)
        }
    }

    func conflictEntry(atStage stage: Int, path: String, in workingDir: String,
                       file: StaticString = #fileID, line: UInt = #line) throws -> ConflictEntry? {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performConflictEntry(atStage: stage, path: path, in: workingDir)
        }
    }

    func restoreConflictEntry(_ entry: ConflictEntry, stage: Int, path: String, at root: String,
                              file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performRestoreConflictEntry(entry, stage: stage, path: path, at: root)
        }
    }

    func retireConflictPath(_ path: String, at root: String,
                            file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performRetireConflictPath(path, at: root)
        }
    }

    func removeConflictEntryFromIndex(_ path: String, at root: String,
                                      file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performRemoveConflictEntryFromIndex(path, at: root)
        }
    }

    func continueRebase(at path: String,
                        file: StaticString = #fileID, line: UInt = #line) throws -> PullResult {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performContinueRebase(at: path)
        }
    }

    func skipRebase(at path: String,
                    file: StaticString = #fileID, line: UInt = #line) throws -> PullResult {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performSkipRebase(at: path)
        }
    }

    func stagePath(_ path: String, at root: String,
                   file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performStagePath(path, at: root)
        }
    }

    func collapseToSingleCommit(at root: String, message: String, credential: GitCredential?,
                                fetchedRevision: FetchedStoreRevision? = nil,
                                file: StaticString = #fileID, line: UInt = #line) throws -> Bool {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performCollapseToSingleCommit(
                at: root,
                message: message,
                credential: credential,
                fetchedRevision: fetchedRevision)
        }
    }

    func hasCommitsToPush(at path: String,
                          file: StaticString = #fileID, line: UInt = #line) throws -> Bool {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performHasCommitsToPush(at: path)
        }
    }

    func log(forPath path: String, at workingDir: String, limit: Int,
             file: StaticString = #fileID, line: UInt = #line) -> [GitCommit] {
        GitThreadGuard.withCallSite(file: file, line: line) {
            performLog(forPath: path, at: workingDir, limit: limit)
        }
    }

    func show(sha: String, path: String, at workingDir: String,
              file: StaticString = #fileID, line: UInt = #line) -> String? {
        GitThreadGuard.withCallSite(file: file, line: line) {
            performShow(sha: sha, path: path, at: workingDir)
        }
    }
}
