import Foundation

// Source defaults capture the caller; typed references dispatch public protocol witnesses.
extension UpdateCheckGitServing {
    func commitDate(at repositoryPath: String,
                    file: StaticString = #fileID, line: UInt = #line) throws -> Date {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String) throws -> Date = self.commitDate
            return try operation(repositoryPath)
        }
    }
}
