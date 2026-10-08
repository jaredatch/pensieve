import Darwin
import Foundation

struct SkillFolderImportResult {
    let directoryName: String
    var skipped: [SkillFolderCopySkip] = []
}

struct SkillFolderCopySkip: Equatable {
    enum Reason: CaseIterable {
        case dotEntry, syncExcluded, link, special, changed
        var heading: String {
            switch self {
            case .dotEntry: "Hidden items left out"
            case .syncExcluded: "Left out because Pensieve doesn't sync them"
            case .link: "Links left out"
            case .special: "Special files left out"
            case .changed: "Changed during import, so left out"
            }
        }
    }
    let path: String
    let reason: Reason
    static func notices(for skipped: [Self]) -> [String] {
        Reason.allCases.compactMap { reason in
            let paths = skipped.filter { $0.reason == reason }.map(\.path).sorted()
            return paths.isEmpty ? nil : reason.heading + ": " + paths.joined(separator: ", ")
        }
    }
}

enum SkillFolderCopyError: LocalizedError {
    case tooManyEntries, tooManyBytes, tooDeep, caseCollision(String, String)
    var errorDescription: String? {
        switch self {
        case .tooManyEntries: "The skill folder is too large (more than 1,000 entries)."
        case .tooManyBytes: "The skill folder is too large (more than 64 MiB of file data)."
        case .tooDeep: "The skill folder is too large (more than 64 folders deep)."
        case .caseCollision(let first, let second): "The skill folder has names that differ only by case: \(first), \(second)."
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
        let limits = FileTreeComparisonLimits(maximumFileBytes: Self.maximumImportBytes,
            maximumFiles: Self.maximumImportEntries, maximumTotalBytes: Self.maximumImportBytes,
            maximumEntries: Self.maximumImportEntries)
        let budget = ComparisonInventoryBudget(limits: limits) { limit in
            switch limit {
            case .entries: SkillFolderCopyError.tooManyEntries
            case .depth: SkillFolderCopyError.tooDeep
            }
        }
        try walkComparisonEntries(root, excludingGit: false, budget: budget,
                                  beforeEntry: { try checkpoint(.entry($0)) }, entry: inventory.admit)
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
            try validateImportSize(opened, maximumBytes: remaining)
            if try importSourceChanged(opened) {
                inventory.skipped.append(SkillFolderCopySkip(path: path, reason: .changed))
                continue
            }
            do {
                let count = try copyFile(from: opened, to: destination + "/" + path,
                    options: .init(maximumBytes: remaining, checkingCancellation: true, read: read), copiedChunk: {
                        try checkpoint(.copiedChunk(path, $0))
                })
                remaining -= count
                if try importSourceChanged(opened) {
                    try deleteFile(at: destination + "/" + path)
                    inventory.skipped.append(SkillFolderCopySkip(path: path, reason: .changed))
                }
            } catch {
                if (error as NSError).domain == NSCocoaErrorDomain,
                   (error as NSError).code == CocoaError.fileReadTooLarge.rawValue { throw SkillFolderCopyError.tooManyBytes }
                throw error
            }
        }
        try root.validate()
        return inventory.skipped.sorted { $0.path < $1.path }
    }

    private func validateImportSize(_ source: ComparisonOpenedFile, maximumBytes: Int) throws {
        guard source.initial.st_size >= 0, source.initial.st_size <= maximumBytes else {
            throw SkillFolderCopyError.tooManyBytes
        }
    }

    private func importSourceChanged(_ source: ComparisonOpenedFile) throws -> Bool {
        do { return try source.changed() } catch {
            let failure = error as NSError
            guard failure.domain == NSPOSIXErrorDomain,
                  [ELOOP, EFTYPE, EISDIR, ENOENT, EOPNOTSUPP].contains(Int32(failure.code)) else { throw error }
            return true
        }
    }

    /// Uses the same descriptor copy as install, retaining its atomic leaf write and read errors.
    private func copyFile(from source: ComparisonOpenedFile, to destination: String,
                          options: DescriptorFileCopy.Options, copiedChunk: (Int) throws -> Void) throws -> Int {
        try DescriptorFileCopy.copy(from: source.descriptor, status: source.initial,
                                   sourcePath: source.entry.path, to: destination, options: options, copiedChunk: copiedChunk)
    }
}

private final class ImportCopyInventory {
    var bytes = 0
    var skillBytes = 0
    var directories: [String] = []
    var files: [(String, ComparisonFile)] = []
    var skipped: [SkillFolderCopySkip] = []
    private var casePaths = ["skill.md": "SKILL.md"]

    func admit(_ directory: ComparisonDirectory, name: String, path: String, status: stat) throws -> Bool {
        let kind = status.st_mode & S_IFMT
        let nameBytes = Data(name.utf8)
        let excluded = kind == S_IFDIR
            ? StoreExclusions.isExcludedDirectory(nameBytes[...])
            : StoreExclusions.isExcludedFile(Data(path.utf8)[...])
        if excluded {
            let reason: SkillFolderCopySkip.Reason = name == ".DS_Store" ? .dotEntry : .syncExcluded
            skipped.append(SkillFolderCopySkip(path: path, reason: reason))
            return false
        }
        if name.utf8.first == 0x2E, kind != S_IFREG || !StoreExclusions.isTemplateFile(nameBytes[...]) {
            skipped.append(SkillFolderCopySkip(path: path, reason: .dotEntry))
            return false
        }
        if kind == S_IFDIR || kind == S_IFREG {
            if let first = casePaths[path.lowercased()], first != path {
                let paths = [first, path].sorted()
                throw SkillFolderCopyError.caseCollision(paths[0], paths[1])
            }
            casePaths[path.lowercased()] = path
        }
        switch kind {
        case S_IFDIR:
            directories.append(path)
            return true
        case S_IFREG:
            guard status.st_size >= 0, status.st_size <= FileService.maximumImportBytes - bytes else {
                throw SkillFolderCopyError.tooManyBytes
            }
            bytes += Int(status.st_size)
            if path == "SKILL.md" {
                skillBytes = Int(status.st_size)
            } else {
                files.append((path, ComparisonFile(directory: directory.reference, name: name, status: status)))
            }
        case S_IFLNK: skipped.append(SkillFolderCopySkip(path: path, reason: .link))
        default: skipped.append(SkillFolderCopySkip(path: path, reason: .special))
        }
        return false
    }
}
