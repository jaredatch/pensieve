import Foundation

extension GitServiceProtocol {
    /// Unmodeled git services cannot certify a commit. This only forfeits the ingest skip.
    @_disfavoredOverload
    func localCommitMatches(_ outputs: [Data: Data], from parent: String, to head: String, at root: String) throws -> Bool {
        false
    }

    func localCommitMatches(_ outputs: [Data: Data], from parent: String, to head: String, at root: String,
                            file: StaticString = #fileID, line: UInt = #line) throws -> Bool {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            let operation: ([Data: Data], String, String, String) throws -> Bool = self.localCommitMatches
            return try operation(outputs, parent, head, root)
        }
    }
}

extension GitService {
    /// Compare the resulting tree with the admitted tree, including a conflict collapse that
    /// rewrote commit ancestry. Raw NUL records retain deletions, mode changes and both rename sides.
    @_disfavoredOverload
    func localCommitMatches(_ outputs: [Data: Data], from parent: String, to head: String, at root: String) throws -> Bool {
        let args = ["-C", root, "diff-tree", "-r", "--raw", "--no-abbrev", "--no-renames",
                    "--ignore-submodules=none", "-z", parent, head, "--"]
        let output = try runData(args, in: nil)
        guard output.exit == 0 else { return false }
        let records = output.stdout.split(separator: 0, omittingEmptySubsequences: false)
        guard records.last?.isEmpty == true, records.count % 2 == 1 else { return false }
        for index in stride(from: 0, to: records.count - 1, by: 2) {
            guard try localChangeMatches(metadata: Data(records[index]), path: Data(records[index + 1]),
                                         outputs: outputs, root: root) else { return false }
        }
        return true
    }

    private func localChangeMatches(metadata: Data, path: Data, outputs: [Data: Data], root: String) throws -> Bool {
        let components = path.split(separator: 0x2F)
        // Machine observations do not feed the library rebuild.
        if components.count > 1, components.first == Data("machines".utf8) { return true }
        let fields = metadata.split(separator: 0x20)
        guard fields.count == 5 else { return false }
        guard let mode = String(bytes: fields[1], encoding: .utf8) else { return false }
        let isManifest = components.count > 1 && components.first == Data("manifest".utf8)
        let isControl = [".gitattributes", ".gitignore", StoreIgnoreRules.receiptFile].contains { Data($0.utf8) == path }
        guard isManifest || isControl else { return false }
        if mode == "000000" {
            guard outputs[path] == nil else { return false }
            return true
        }
        guard mode == "100644", let expected = outputs[path] else { return false }
        guard let object = String(bytes: fields[3], encoding: .utf8) else { return false }
        let blob = try runData(["-C", root, "cat-file", "blob", object], in: nil)
        guard blob.exit == 0, blob.stdout == expected else { return false }
        return true
    }

}
