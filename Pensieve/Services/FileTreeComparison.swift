import Foundation

struct FileTreeComparisonLimits {
    static let updatePreview = FileTreeComparisonLimits(maximumFileBytes: 1_024 * 1_024,
                                                       maximumFiles: 1_000, maximumTotalBytes: 32 * 1_024 * 1_024)
    static let maximumInventoryEntries = 20_000
    static let maximumDirectoryDepth = 64
    let maximumEntries: Int
    let maximumDepth: Int
    let maximumFileBytes: Int
    let maximumFiles: Int
    let maximumTotalBytes: Int
    init(maximumFileBytes: Int, maximumFiles: Int, maximumTotalBytes: Int,
         maximumEntries: Int = maximumInventoryEntries, maximumDepth: Int = maximumDirectoryDepth) {
        self.maximumFileBytes = maximumFileBytes
        self.maximumFiles = maximumFiles
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumEntries = maximumEntries
        self.maximumDepth = maximumDepth
    }
}

enum FileTreeComparisonError: LocalizedError {
    case treeTooLarge
    var errorDescription: String? { "This skill is too large to preview." }
}

struct FileTreeChange: Equatable {
    enum Kind { case added, removed, modified }
    enum Content: Equatable {
        case text(old: String, new: String)
        case modeOnly
        case binary
        case tooLarge
        case diffBudgetExhausted
        case diffOutputBoundReached
        case diffOutputTooLarge
    }
    let path: String
    let kind: Kind
    let content: Content
    let permissions: Permissions?

    struct Permissions: Equatable {
        let old: UInt32
        let new: UInt32
    }

    init(path: String, kind: Kind, content: Content, permissions: Permissions? = nil) {
        self.path = path
        self.kind = kind
        self.content = content
        self.permissions = permissions
    }
}

struct FileTreeComparison: Equatable {
    let changes: [FileTreeChange]
    let unreadFileCount: Int
    let bytesRead: Int
    var isIncomplete: Bool { unreadFileCount > 0 }
}
