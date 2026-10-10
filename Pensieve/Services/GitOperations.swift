import Foundation

protocol GitUsabilityProbing {
    @_disfavoredOverload
    func probeUsability() throws -> GitUsability
}

protocol GitRemoteReading {
    @_disfavoredOverload
    func remoteURL(at path: String) throws -> String?
}

protocol GitShallowCloning {
    @_disfavoredOverload
    func cloneShallow(remote: String, branch: String?, into path: String,
                      credential: GitCredential?) throws
}

protocol GitCommitReading {
    @_disfavoredOverload
    func commitSHA(at path: String) throws -> String
}

protocol GitTreeReading {
    @_disfavoredOverload
    func treeHash(at repositoryPath: String, path: String) throws -> String
}

protocol GitRemoteHeadReading {
    @_disfavoredOverload
    func remoteHead(remote: String, ref: String,
                    credential: GitCredential?) throws -> String?
}

// The requirement keeps the public operation name. Prefer this source-default overload at
// entries, then use a typed reference to dispatch the requirement without selecting this overload
// again. Consumer protocols inherit the same operation, so they cannot acquire competing wrappers.
extension GitUsabilityProbing {
    func probeUsability(file: StaticString = #fileID, line: UInt = #line) throws -> GitUsability {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: () throws -> GitUsability = self.probeUsability
            return try operation()
        }
    }
}

extension GitRemoteReading {
    func remoteURL(at path: String,
                   file: StaticString = #fileID, line: UInt = #line) throws -> String? {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String) throws -> String? = self.remoteURL
            return try operation(path)
        }
    }
}

extension GitShallowCloning {
    func cloneShallow(remote: String, branch: String?, into path: String,
                      credential: GitCredential?,
                      file: StaticString = #fileID, line: UInt = #line) throws {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String, String?, String, GitCredential?) throws -> Void = self.cloneShallow
            return try operation(remote, branch, path, credential)
        }
    }
}

extension GitCommitReading {
    func commitSHA(at path: String,
                   file: StaticString = #fileID, line: UInt = #line) throws -> String {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String) throws -> String = self.commitSHA
            return try operation(path)
        }
    }
}

extension GitTreeReading {
    func treeHash(at repositoryPath: String, path: String,
                  file: StaticString = #fileID, line: UInt = #line) throws -> String {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String, String) throws -> String = self.treeHash
            return try operation(repositoryPath, path)
        }
    }
}

extension GitRemoteHeadReading {
    func remoteHead(remote: String, ref: String,
                    credential: GitCredential?,
                    file: StaticString = #fileID, line: UInt = #line) throws -> String? {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String, String, GitCredential?) throws -> String? = self.remoteHead
            return try operation(remote, ref, credential)
        }
    }
}
