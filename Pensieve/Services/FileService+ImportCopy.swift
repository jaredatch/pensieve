import Darwin
import Foundation

struct SkillFolderImportResult {
    let directoryName: String
    var skipped: [SkillFolderCopySkip] = []
}

struct SkillFolderCopySkip: Equatable {
    enum Reason: String {
        case dotEntry = "dot-entry", link = "a link", special = "a special file", changed = "changed during the copy"
        case syncExcluded = "excluded from sync"
    }
    let path: String
    let reason: Reason
    var notice: String { "Skipped \(path): \(reason.rawValue)." }
}

enum SkillFolderCopyError: LocalizedError {
    case tooManyEntries, tooManyBytes
    var errorDescription: String? {
        switch self {
        case .tooManyEntries: "The skill folder is too large (more than 1,000 entries)."
        case .tooManyBytes: "The skill folder is too large (more than 64 MiB of file data)."
        }
    }
}

extension FileService {
    static let maximumImportEntries = 1_000
    static let maximumImportBytes = 64 * 1_024 * 1_024

    enum ImportCopyCheckpoint {
        case entry(String), inventoried, copying(String), copiedChunk(String, Int)
    }

    /// Resolves the selected folder once, then traverses and reopens children relative to admitted
    /// directory descriptors. Excluded subtrees and nonregular leaves are never opened. Inventory and
    /// descriptor reads enforce one folder budget; the caller owns temp cleanup and publication.
    func copyImportedSkillContents(fromDirectory source: String,
                                   toDirectory destination: String) throws -> [SkillFolderCopySkip] {
        try copyImportedSkillContents(fromDirectory: source, toDirectory: destination, checkpoint: { _ in })
    }

    func copyImportedSkillContents(fromDirectory source: String, toDirectory destination: String,
                                   checkpoint: (ImportCopyCheckpoint) throws -> Void,
                                   read: @escaping (Int32, UnsafeMutableRawPointer?, Int) -> Int = Darwin.read
    ) throws -> [SkillFolderCopySkip] {
        let root = try ComparisonDirectory(path: resolveRealPath(at: source), name: "", parent: nil)
        let inventory = ImportCopyInventory()
        try inventory.collect(root, relative: "", checkpoint: checkpoint)
        try checkpoint(.inventoried)
        for path in inventory.directories { try createDirectory(at: destination + "/" + path) }
        // SKILL.md was already read by discovery and is replaced by prepared text, not copied again.
        var remaining = Self.maximumImportBytes - inventory.skillBytes
        for (path, entry) in inventory.files.sorted(by: { $0.0 < $1.0 }) {
            try checkpoint(.copying(path))
            let opened: ComparisonOpenedFile
            do { opened = try entry.open() } catch {
                let failure = error as NSError
                guard failure.domain == NSPOSIXErrorDomain,
                      [ELOOP, EFTYPE, EISDIR, ENOENT, EOPNOTSUPP].contains(Int32(failure.code)) else { throw error }
                inventory.skipped.append(SkillFolderCopySkip(path: path, reason: .changed))
                continue
            }
            do {
                let count = try copyFile(from: opened, to: destination + "/" + path,
                    options: .init(maximumBytes: remaining, read: read), copiedChunk: {
                        try checkpoint(.copiedChunk(path, $0))
                    })
                remaining -= count
            } catch {
                if (error as NSError).domain == NSCocoaErrorDomain,
                   (error as NSError).code == CocoaError.fileReadTooLarge.rawValue { throw SkillFolderCopyError.tooManyBytes }
                throw error
            }
        }
        try root.validate()
        return inventory.skipped.sorted { $0.path < $1.path }
    }

    /// Uses the same descriptor copy as install, retaining its atomic leaf write and read errors.
    private func copyFile(from source: ComparisonOpenedFile, to destination: String,
                          options: DescriptorFileCopy.Options, copiedChunk: (Int) throws -> Void) throws -> Int {
        try DescriptorFileCopy.copy(from: source.descriptor, status: source.initial,
                                   sourcePath: source.entry.path, to: destination, options: options, copiedChunk: copiedChunk)
    }
}

private final class ImportCopyInventory {
    var entries = 0
    var bytes = 0
    var skillBytes = 0
    var directories: [String] = []
    var files: [(String, ComparisonFile)] = []
    var skipped: [SkillFolderCopySkip] = []

    func collect(_ directory: ComparisonDirectory, relative: String,
                 checkpoint: (FileService.ImportCopyCheckpoint) throws -> Void) throws {
        try directory.forEachEntry(excludingGit: false, beforeEntry: { name in
            let path = relative.isEmpty ? name : relative + "/" + name
            try checkpoint(.entry(path))
            entries += 1
            guard entries <= FileService.maximumImportEntries else { throw SkillFolderCopyError.tooManyEntries }
        }, body: { name, status in
            let path = relative.isEmpty ? name : relative + "/" + name
            let kind = status.st_mode & S_IFMT
            let nameBytes = Data(name.utf8)
            let excluded = kind == S_IFDIR
                ? StoreExclusions.isExcludedDirectory(nameBytes[...])
                : StoreExclusions.isExcludedFile(Data(path.utf8)[...])
            if excluded {
                skipped.append(SkillFolderCopySkip(path: path, reason: .syncExcluded))
                return
            }
            if name.utf8.first == 0x2E, kind != S_IFREG || !StoreExclusions.isTemplateFile(nameBytes[...]) {
                skipped.append(SkillFolderCopySkip(path: path, reason: .dotEntry))
                return
            }
            switch kind {
            case S_IFDIR:
                directories.append(path)
                let child = try ComparisonDirectory(path: directory.path + "/" + name, name: name, parent: directory)
                try collect(child, relative: path, checkpoint: checkpoint)
            case S_IFREG:
                guard status.st_size >= 0, status.st_size <= FileService.maximumImportBytes - bytes else {
                    throw SkillFolderCopyError.tooManyBytes
                }
                bytes += Int(status.st_size)
                if relative.isEmpty, name.caseInsensitiveCompare("SKILL.md") == .orderedSame {
                    skillBytes = Int(status.st_size)
                } else {
                    files.append((path, ComparisonFile(directory: directory.reference, name: name, status: status)))
                }
            case S_IFLNK: skipped.append(SkillFolderCopySkip(path: path, reason: .link))
            default: skipped.append(SkillFolderCopySkip(path: path, reason: .special))
            }
        })
    }
}
