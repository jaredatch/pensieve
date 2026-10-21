import CryptoKit
import Foundation

/// The caller owns path policy; Git only verifies the resulting tree and regular-file bytes.
struct GitTreeExpectation {
    let files: [Data: Data]
    let deletablePaths: Set<Data>
    let deletablePrefixes: [Data]
    let ignoredPrefixes: [Data]
}

extension GitServiceProtocol {
    /// Unmodeled services conservatively capture and decline certification.
    @_disfavoredOverload
    func hasUncommittedChanges(at path: String) -> Bool { true }

    func hasUncommittedChanges(at path: String, file: StaticString = #fileID, line: UInt = #line) -> Bool {
        GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (String) -> Bool = self.hasUncommittedChanges
            return operation(path)
        }
    }

    @_disfavoredOverload
    func localCommitMatches(_ expected: GitTreeExpectation, from parent: String, to head: String,
                            at root: String) throws -> Bool {
        false
    }

    func localCommitMatches(_ expected: GitTreeExpectation, from parent: String, to head: String, at root: String,
                            file: StaticString = #fileID, line: UInt = #line) throws -> Bool {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: (GitTreeExpectation, String, String, String) throws -> Bool = self.localCommitMatches
            return try operation(expected, parent, head, root)
        }
    }
}

extension GitService {
    @_disfavoredOverload
    func hasUncommittedChanges(at path: String) -> Bool { !isWorktreeClean(at: path) }

    /// Compare trees across ordinary commits and rewritten ancestry. Raw NUL records preserve paths.
    @_disfavoredOverload
    func localCommitMatches(_ expected: GitTreeExpectation, from parent: String, to head: String,
                            at root: String) throws -> Bool {
        let args = ["-C", root, "diff-tree", "-r", "--raw", "--no-abbrev", "--no-renames",
                    "--ignore-submodules=none", "-z", parent, head, "--"]
        let output = try runData(args, in: nil)
        guard output.exit == 0 else { return false }
        let records = output.stdout.split(separator: 0, omittingEmptySubsequences: false)
        guard records.last?.isEmpty == true, records.count % 2 == 1 else { return false }
        for index in stride(from: 0, to: records.count - 1, by: 2) {
            guard localChangeMatches(metadata: Data(records[index]), path: Data(records[index + 1]),
                                     expected: expected) else { return false }
        }
        return true
    }

    private func localChangeMatches(metadata: Data, path: Data, expected: GitTreeExpectation) -> Bool {
        let fields = metadata.split(separator: 0x20)
        guard fields.count == 5, fields[0].first == 0x3A,
              let oldMode = String(bytes: fields[0].dropFirst(), encoding: .utf8),
              let mode = String(bytes: fields[1], encoding: .utf8) else { return false }
        if expected.ignoredPrefixes.contains(where: { path.starts(with: $0) }) {
            // Neither side of an ignored observation may be a link, gitlink or executable.
            return [oldMode, mode].allSatisfy { $0 == "000000" || $0 == "100644" }
        }
        if mode == "000000" {
            return expected.files[path] == nil && (expected.deletablePaths.contains(path)
                || expected.deletablePrefixes.contains { path.starts(with: $0) })
        }
        guard mode == "100644", let bytes = expected.files[path],
              let object = String(bytes: fields[3], encoding: .utf8) else { return false }
        let header = Data("blob \(bytes.count)\0".utf8)
        // --no-abbrev returns the repository's full object IDs, including SHA-256 repositories.
        let digest: [UInt8]
        switch object.utf8.count {
        case 40:
            var hash = Insecure.SHA1()
            hash.update(data: header)
            hash.update(data: bytes)
            digest = Array(hash.finalize())
        case 64:
            var hash = SHA256()
            hash.update(data: header)
            hash.update(data: bytes)
            digest = Array(hash.finalize())
        default: return false
        }
        return digest.map { String(format: "%02x", $0) }.joined() == object
    }
}
