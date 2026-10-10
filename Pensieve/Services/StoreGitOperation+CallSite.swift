import Foundation

/// Preserve the outside source while an operation enters nested git helpers.
extension StoreGitOperation {
    @discardableResult
    func run(_ args: [String], credential: GitCredential? = nil,
             file: StaticString = #fileID, line: UInt = #line) throws -> GitService.GitOutput {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performRun(args, credential: credential)
        }
    }

    @discardableResult
    func runOrThrow(_ args: [String],
                    file: StaticString = #fileID, line: UInt = #line) throws -> GitService.GitOutput {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performRunOrThrow(args)
        }
    }

    func runData(_ args: [String],
                 file: StaticString = #fileID, line: UInt = #line) throws -> GitService.GitDataOutput {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performRunData(args)
        }
    }

    func commitStagedChanges(message: String,
                             file: StaticString = #fileID, line: UInt = #line) throws -> Bool {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performCommitStagedChanges(message: message)
        }
    }

    func pullArguments(for revision: FetchedStoreRevision,
                       file: StaticString = #fileID, line: UInt = #line) throws -> [String] {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performPullArguments(for: revision)
        }
    }

    func unstagedSkillPaths(file: StaticString = #fileID, line: UInt = #line) throws -> Data {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performUnstagedSkillPaths()
        }
    }

    func ordinaryUntrackedPaths(file: StaticString = #fileID, line: UInt = #line) throws -> Data {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performOrdinaryUntrackedPaths()
        }
    }

    func excludedUntrackedPaths(file: StaticString = #fileID, line: UInt = #line) throws -> [Data] {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performExcludedUntrackedPaths()
        }
    }

    func requireNoExcludedCollision(with revision: String, localPaths: [Data]? = nil,
                                    file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performRequireNoExcludedCollision(with: revision, localPaths: localPaths)
        }
    }

    func stage(file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performStage()
        }
    }

    func stagePath(_ path: String,
                   file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performStagePath(path)
        }
    }
}

// Capture the source before entering implementation helpers or closures.
extension GitService {
    func storeOperation(at root: String, file: StaticString = #fileID, line: UInt = #line) throws -> StoreGitOperation {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performStoreOperation(at: root)
        }
    }

    func fetchStoreRevision(at path: String, credential: GitCredential?,
                            file: StaticString = #fileID, line: UInt = #line) throws -> FetchedStoreRevision {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performFetchStoreRevision(at: path, credential: credential)
        }
    }
}
