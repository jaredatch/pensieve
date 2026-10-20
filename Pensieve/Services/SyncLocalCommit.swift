import Foundation

/// A cycle-local copy of the tree just published from the window and the generated controls.
/// Other Pensieve writes have no provenance here and deliberately cost a later rebuild.
struct SyncLocalCommit {
    let outputs: [Data: Data]

    init(root: String, files: FileServiceProtocol) throws {
        var captured: [Data: Data] = [:]
        func capture(_ path: String) throws {
            let absolute = root + "/" + path
            switch try files.entryTypeWithoutFollowingLinks(at: absolute) {
            case nil: break
            case .directory:
                for name in try files.listDirectory(at: absolute) { try capture(path + "/" + name) }
            case .regular:
                captured[Data(path.utf8)] = try files.readRegularFileData(at: absolute, maximumBytes: Int.max, containedIn: root)
            default: throw CocoaError(.fileReadUnknown)
            }
        }
        try capture("manifest")
        // A directory at .gitignore is preserved user data, not generated output.
        for path in [".gitattributes", ".gitignore", StoreIgnoreRules.receiptFile]
            where try files.entryTypeWithoutFollowingLinks(at: root + "/" + path) == .regular {
            try capture(path)
        }
        outputs = captured
    }

    func record(from parent: String?, to head: String?, root: String,
                git: GitServiceProtocol, state: StoreIngestState) {
        guard let parent, let head,
              (try? git.localCommitMatches(outputs, from: parent, to: head, at: root)) == true else { return }
        state.recordLocalCommit(from: parent, to: head)
    }
}
