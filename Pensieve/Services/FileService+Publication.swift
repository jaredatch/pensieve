import Darwin
import Foundation

extension FileServiceProtocol {
    /// Atomically publish over an absent or empty directory, preserving every other occupant.
    func publishDirectory(at sourcePath: String, to destinationPath: String) throws {
        try publishDirectory(at: sourcePath, to: destinationPath, exclusively: false)
    }

    /// Atomically publish only to an absent entry, refusing files, links and even empty folders.
    func publishNewDirectory(at sourcePath: String, to destinationPath: String) throws {
        try publishDirectory(at: sourcePath, to: destinationPath, exclusively: true)
    }

    /// One FileService boundary for both rename modes. Source and destination must share a volume.
    private func publishDirectory(at sourcePath: String, to destinationPath: String, exclusively: Bool) throws {
        let operation = exclusively ? "publish new directory" : "publish directory"
        guard try entryTypeWithoutFollowingLinks(at: sourcePath) == .directory else {
            throw DescriptorFileCopy.error(operation, path: sourcePath, code: ENOTDIR)
        }
        let result = exclusively
            ? renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
            : Darwin.rename(sourcePath, destinationPath)
        guard result == 0 else {
            let code = errno
            if !exclusively && (code == ENOTEMPTY || code == EEXIST || code == ENOTDIR) {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                    NSFilePathErrorKey: destinationPath,
                    NSLocalizedDescriptionKey:
                        "The store destination '\(destinationPath)' already exists and is not an empty directory."
                ])
            }
            throw DescriptorFileCopy.error(operation, path: destinationPath, code: code)
        }
    }
}
