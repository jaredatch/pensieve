import Foundation

struct FileTreeComparisonLimits {
    static let updatePreview = FileTreeComparisonLimits(maximumFileBytes: 1_024 * 1_024,
                                                       maximumFiles: 1_000, maximumTotalBytes: 32 * 1_024 * 1_024)
    let maximumFileBytes: Int
    let maximumFiles: Int
    let maximumTotalBytes: Int
}

struct FileTreeChange: Equatable {
    enum Kind { case added, removed, modified }
    enum Content: Equatable {
        case text(old: String, new: String)
        case binary
        case tooLarge
    }
    let path: String
    let kind: Kind
    let content: Content
}

struct FileTreeComparison: Equatable {
    let changes: [FileTreeChange]
    let unreadFileCount: Int
    let bytesRead: Int
    var isIncomplete: Bool { unreadFileCount > 0 }
}
