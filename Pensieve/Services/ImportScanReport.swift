import Foundation

struct ImportScanReport: Equatable {
    var skills: [DiscoveredSkill] = []
    var skipped: [ImportScanSkip] = []

    var summary: String? {
        guard !skipped.isEmpty else { return nil }
        let reasons = ImportScanSkip.Reason.allCases.compactMap { reason -> String? in
            let count = skipped.filter { $0.reason == reason }.count
            guard count > 0 else { return nil }
            return "\(count) \(reason.label(count: count))"
        }
        let entries = skipped.count == 1 ? "entry" : "entries"
        return "Skipped \(skipped.count) \(entries): " + reasons.joined(separator: "; ") + "."
    }
}

struct ImportScanSkip: Equatable {
    enum Reason: CaseIterable {
        case notRegular, tooLarge, unreadable, invalidUTF8

        func label(count: Int) -> String {
            let maximumMiB = ImportScanner.maximumFileBytes / (1_024 * 1_024)
            return switch self {
            case .notRegular: count == 1 ? "symlink or special file" : "symlinks or special files"
            case .tooLarge: count == 1 ? "file larger than \(maximumMiB) MiB" : "files larger than \(maximumMiB) MiB"
            case .unreadable: count == 1 ? "unreadable file or folder" : "unreadable files or folders"
            case .invalidUTF8: count == 1 ? "file that isn't UTF-8 text" : "files that aren't UTF-8 text"
            }
        }
    }

    let path: String
    let reason: Reason
}
