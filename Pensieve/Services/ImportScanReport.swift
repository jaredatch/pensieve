import Foundation

struct ImportScanReport: Equatable {
    var skills: [DiscoveredSkill] = []
    var skipped: [ImportScanSkip] = []
}

struct ImportScanSkip: Equatable {
    enum Reason: String, CaseIterable {
        case notRegular = "symlinks or special files"
        case tooLarge = "files larger than 4 MiB"
        case unreadable = "unreadable files or folders"
        case invalidUTF8 = "files that aren't UTF-8 text"
    }

    let path: String
    let reason: Reason
}
