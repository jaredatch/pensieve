import Darwin
import Foundation

extension FileServiceProtocol {
    /// Publish a new directory with one rename, refusing any destination entry, even an empty folder.
    /// Source and destination must share a volume. Like replaceItem, this primitive stays in FileService.
    func publishNewDirectory(at sourcePath: String, to destinationPath: String) throws {
        guard try entryTypeWithoutFollowingLinks(at: sourcePath) == .directory else {
            throw DescriptorFileCopy.error("publish new directory", path: sourcePath, code: ENOTDIR)
        }
        guard renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL)) == 0 else {
            throw DescriptorFileCopy.error("publish new directory", path: destinationPath, code: errno)
        }
    }
}
