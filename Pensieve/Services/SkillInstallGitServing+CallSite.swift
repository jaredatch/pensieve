import Foundation

// Source defaults capture the caller; typed references dispatch public protocol witnesses.
extension SkillInstallGitServing {
    func currentBranch(at path: String,
                       file: StaticString = #fileID, line: UInt = #line) throws -> String {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String) throws -> String = self.currentBranch
            return try operation(path)
        }
    }
}
