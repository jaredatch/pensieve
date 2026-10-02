import Foundation

/// What a skill's directory holds, read once off the render path — the Overview's Bundle stat and
/// Contents list, the Content tab's file pulldown (PLAN-34): every regular file under the directory
/// with its size, and a token estimate for the ones that decode as UTF-8 text. A hidden entry or a name
/// the read would refuse is skipped, a symlink is never followed (C7), and `truncated` says the walk stopped
/// before reading everything it met: the file cap reached with a file still to read, a directory past the
/// depth cap (not looked inside, so it counts even when empty), or a directory or file that could not be read.
/// `files` is sorted by relative path, so the result is deterministic.
struct SkillBundleInventory: Equatable {
    struct File: Equatable, Identifiable {
        let relativePath: String
        let bytes: Int
        /// nil for a file that is not UTF-8 text (an image, an archive).
        let tokens: Int?
        var id: String { relativePath }
    }

    var files: [File] = []
    var truncated = false

    static let empty = SkillBundleInventory()
    static let maxFiles = 500
    static let maxDepth = 8

    var fileCount: Int { files.count }
    var totalBytes: Int { files.reduce(0) { $0 + $1.bytes } }
    var textFiles: [File] { files.filter { $0.tokens != nil } }

    /// Walk `root`, a directory the caller has already passed through `SkillStore.safeSkillDirectory`.
    static func scan(root: String, fileService: FileServiceProtocol) -> SkillBundleInventory {
        var inventory = SkillBundleInventory()
        walk(directory: root, prefix: "", depth: 0, fileService: fileService, into: &inventory)
        inventory.files.sort { $0.relativePath < $1.relativePath }
        return inventory
    }

    private static func walk(directory: String, prefix: String, depth: Int,
                             fileService: FileServiceProtocol, into inventory: inout SkillBundleInventory) {
        guard depth <= maxDepth else { inventory.truncated = true; return }
        // A directory the process cannot list leaves the inventory incomplete, and it says so.
        guard let entries = try? fileService.listDirectory(at: directory) else { inventory.truncated = true; return }
        // The read's own name predicate (`SkillStore.isPathSafeSlug`): no dot name, no leading dot, no backslash,
        // no control character — so every text file the inventory lists, `bundleFileText` reads (a binary is
        // listed, with nil tokens, and reads nil).
        for name in entries.sorted() where SkillStore.isPathSafeSlug(name) {
            // Once the cap is spent and a file was left out, nothing further is read.
            if inventory.truncated && inventory.files.count >= maxFiles { return }
            let path = directory + "/" + name
            let relative = prefix.isEmpty ? name : prefix + "/" + name
            if fileService.isSymlink(at: path) { continue }
            if fileService.directoryExists(at: path) {
                walk(directory: path, prefix: relative, depth: depth + 1, fileService: fileService, into: &inventory)
            } else if fileService.isRegularFile(at: path) {
                // The cap is spent on files, checked where a file would be appended: exactly the cap followed by a
                // directory or a symlink is not a truncation.
                if inventory.files.count >= maxFiles { inventory.truncated = true; return }
                guard let data = try? fileService.readData(at: path) else { inventory.truncated = true; continue }
                let tokens = String(data: data, encoding: .utf8).map { TokenCounter.estimate($0) }
                inventory.files.append(File(relativePath: relative, bytes: data.count, tokens: tokens))
            }
        }
    }
}
