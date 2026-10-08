import CryptoKit
import Foundation

extension SkillInstallService {
    private struct VendorEntry {
        let relativePath: String
        let isDirectory: Bool
    }

    func stableContentHash(at directory: String,
                           excludingTopLevelGitMetadata: Bool = false) throws -> String {
        let entries = try regularTree(
            at: directory,
            excludingTopLevelGitMetadata: excludingTopLevelGitMetadata
        ).filter { !$0.isDirectory }.sorted {
            Data($0.relativePath.utf8).lexicographicallyPrecedes(Data($1.relativePath.utf8))
        }
        var hasher = SHA256()
        var entryCount = UInt64(entries.count).bigEndian
        withUnsafeBytes(of: &entryCount) { hasher.update(data: Data($0)) }
        for entry in entries {
            let path = directory + "/" + entry.relativePath
            let pathDigest = SHA256.hash(data: Data(entry.relativePath.utf8))
            let contentDigest = SHA256.hash(data: try fileService.readData(at: path))
            hasher.update(data: Data(pathDigest))
            hasher.update(data: Data([
                fileService.isUserExecutableFile(at: path) ? 0x78 : 0x2D
            ]))
            hasher.update(data: Data(contentDigest))
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func vendor(sourceDirectory: String, to destination: String,
                excludingTopLevelGitMetadata: Bool,
                beforeReplace: () throws -> Void = {}) throws {
        let entries = try regularTree(
            at: sourceDirectory,
            excludingTopLevelGitMetadata: excludingTopLevelGitMetadata
        )
        let temp = VendorTemporaryDirectory.makePath(storeRoot: storeRoot)
        do {
            try fileService.createDirectory(at: temp)
            for entry in entries where entry.isDirectory {
                try fileService.createDirectory(at: temp + "/" + entry.relativePath)
            }
            for entry in entries where !entry.isDirectory {
                try fileService.copyFile(
                    at: sourceDirectory + "/" + entry.relativePath,
                    to: temp + "/" + entry.relativePath
                )
            }
            try beforeReplace()
            try fileService.replaceItem(at: destination, with: temp)
        } catch {
            if fileService.directoryExists(at: temp) || fileService.isSymlink(at: temp) {
                try? fileService.deleteDirectory(at: temp)
            }
            throw error
        }
    }

    static func cleanupVendorTemps(
        fileService: FileServiceProtocol = FileService(),
        storeRoot: String,
        lockPath: String,
        externallyHeldLock: Bool = false
    ) {
        let lock = externallyHeldLock ? nil : SyncLock.tryAcquire(at: lockPath)
        guard externallyHeldLock || lock != nil else { return }
        defer { lock?.release() }
        let (parent, prefix) = VendorTemporaryDirectory.namespace(storeRoot: storeRoot)
        guard !fileService.isSymlink(at: parent),
              fileService.directoryExists(at: parent),
              let entries = try? fileService.listDirectory(at: parent) else {
            return
        }
        // Match only our UUID namespace, never a user's similarly named sibling.
        for entry in entries where VendorTemporaryDirectory.contains(entry, prefix: prefix) {
            let path = parent + "/" + entry
            if fileService.directoryExists(at: path) || fileService.isSymlink(at: path) {
                try? fileService.deleteDirectory(at: path)
            } else if fileService.fileExists(at: path) {
                try? fileService.deleteFile(at: path)
            }
        }
    }

    private func regularTree(at root: String,
                             excludingTopLevelGitMetadata: Bool) throws -> [VendorEntry] {
        guard !fileService.isSymlink(at: root), fileService.directoryExists(at: root) else {
            throw SkillInstallError.unsupportedFileType(root)
        }
        var entries: [VendorEntry] = []
        try collectRegularTree(
            root: root,
            relativeDirectory: "",
            excludingTopLevelGitMetadata: excludingTopLevelGitMetadata,
            into: &entries
        )
        return entries
    }

    private func collectRegularTree(root: String, relativeDirectory: String,
                                    excludingTopLevelGitMetadata: Bool,
                                    into entries: inout [VendorEntry]) throws {
        let directory = relativeDirectory.isEmpty ? root : root + "/" + relativeDirectory
        for name in try fileService.listDirectory(at: directory) {
            if excludingTopLevelGitMetadata, relativeDirectory.isEmpty, name == ".git" {
                continue
            }
            let relative = relativeDirectory.isEmpty ? name : relativeDirectory + "/" + name
            let path = root + "/" + relative
            if fileService.isSymlink(at: path) {
                throw SkillInstallError.unsupportedFileType(relative)
            }
            if fileService.directoryExists(at: path) {
                entries.append(VendorEntry(relativePath: relative, isDirectory: true))
                try collectRegularTree(
                    root: root,
                    relativeDirectory: relative,
                    excludingTopLevelGitMetadata: excludingTopLevelGitMetadata,
                    into: &entries
                )
            } else if fileService.isRegularFile(at: path) {
                entries.append(VendorEntry(relativePath: relative, isDirectory: false))
            } else {
                throw SkillInstallError.unsupportedFileType(relative)
            }
        }
    }
}
