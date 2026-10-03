import Foundation

struct ImportScanReport: Equatable {
    var skills: [DiscoveredSkill] = []
    var skipped: [ImportScanSkip] = []
}

struct ImportScanSkip: Equatable {
    enum Reason: CaseIterable {
        case notRegular, tooLarge, unreadable, invalidUTF8

        func label(count: Int) -> String {
            switch self {
            case .notRegular: count == 1 ? "symlink or special file" : "symlinks or special files"
            case .tooLarge: count == 1 ? "file larger than 4 MiB" : "files larger than 4 MiB"
            case .unreadable: count == 1 ? "unreadable file or folder" : "unreadable files or folders"
            case .invalidUTF8: count == 1 ? "file that isn't UTF-8 text" : "files that aren't UTF-8 text"
            }
        }
    }

    let path: String
    let reason: Reason
}
