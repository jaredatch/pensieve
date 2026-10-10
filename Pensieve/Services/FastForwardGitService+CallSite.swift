import Foundation

// Source defaults capture the caller; typed references dispatch public protocol witnesses.
extension FastForwardGitService {
    func isWorktreeClean(at path: String,
                         file: StaticString = #fileID, line: UInt = #line) -> Bool {
        GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String) -> Bool = self.isWorktreeClean
            return operation(path)
        }
    }

    func fetch(at path: String, credential: GitCredential?,
               file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String, GitCredential?) throws -> Void = self.fetch
            return try operation(path, credential)
        }
    }

    func fastForwardOnly(at path: String, credential: GitCredential?,
                         file: StaticString = #fileID, line: UInt = #line) throws -> FastForwardResult {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String, GitCredential?) throws -> FastForwardResult = self.fastForwardOnly
            return try operation(path, credential)
        }
    }
}
