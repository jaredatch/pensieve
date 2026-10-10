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

}
