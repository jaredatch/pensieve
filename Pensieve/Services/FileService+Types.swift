import Darwin
import Foundation

enum FileEntryType { case directory, symlink, regular, other }

/// A file's identity on its volume; see `FileServiceProtocol.fileIdentity(at:followingLinks:)`.
struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

struct RegularFileMetadata: Equatable {
    let byteCount: Int
    let modificationDate: Date
}
