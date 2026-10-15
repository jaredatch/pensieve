import Foundation
import os

enum StoreReceiptError: LocalizedError {
    case unreadable(String)
    case invalidPath(String)

    var errorDescription: String? {
        switch self {
        case let .unreadable(path): return "Sync stopped because retirement receipts at \(path) cannot be read exactly."
        case let .invalidPath(path):
            let preview = path.unicodeScalars.prefix(100).map { scalar in
                let category = scalar.properties.generalCategory
                return category == .control || category == .format
                    || category == .lineSeparator || category == .paragraphSeparator
                    ? " " : String(scalar)
            }.joined()
            let suffix = path.unicodeScalars.prefix(101).count > 100 ? "…" : ""
            return "Sync stopped because a retirement receipt names an unsafe store path: \(preview)\(suffix)."
        }
    }
}

/// Receipts live separately from the control files older builds regenerate. Only metadata ignore
/// rules consume them. Root .gitignore stays compatible with older builds; .gitattributes
/// includes only the active manifest families.
enum StoreIgnoreRules {
    static let receiptFile = ".pensieve-retired-paths"
    private static let marker = "# Pensieve retired path: "
    private static let attributes = "manifest/categories/*.yaml merge=union\n"
        + "manifest/projects.yaml merge=union\n"

    struct Receipts {
        var safe: Set<String> = []
        var unsafe: Set<String> = []
        var sources: [String: String] = [:]
    }

    static func retiredPaths(at root: String, files: FileServiceProtocol) throws -> [String] {
        try readReceipts(at: root, files: files).safe.sorted()
    }

    static func readReceipts(at root: String, files: FileServiceProtocol) throws -> Receipts {
        var receipts = Receipts()
        // Read both sources completely before writes or logging. Malformed input remains a stop.
        for source in [".gitattributes", receiptFile] {
            let full = root + "/" + source
            guard try files.entryTypeWithoutFollowingLinks(at: full) != nil else { continue }
            let data = try files.readRegularFileData(at: full, maximumBytes: 1_048_576, containedIn: root)
            guard let text = String(data: data, encoding: .utf8) else { throw StoreReceiptError.unreadable(full) }
            receipts.sources[source] = text
            for line in receiptLines(text) where line.hasPrefix(marker) {
                guard let data = Data(base64Encoded: String(line.dropFirst(marker.count))),
                      let path = String(data: data, encoding: .utf8), hasValidSyntax(path) else {
                    throw StoreReceiptError.invalidPath(line)
                }
                if canRetire(path) { receipts.safe.insert(path) } else { receipts.unsafe.insert(path) }
            }
        }
        return receipts
    }

    /// Git's union driver separates records at LF. Accept CRLF too, without treating a bare
    /// CR or a Unicode line separator inside a record as another receipt.
    private static func receiptLines(_ text: String) -> [String] {
        let records = text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false)
        // The source is valid UTF-8; splitting at ASCII LF cannot cut a scalar.
        return records.enumerated().compactMap { index, record in
            let bytes = index < records.count - 1 && record.last == 0x0D ? record.dropLast() : record
            return String(bytes: bytes, encoding: .utf8)
        }
    }

    /// One rule for receipt consumption, creation and legacy gitlink choices.
    static func canRetire(_ path: String) -> Bool {
        let parts = PathSyntax.components(path, omittingEmptySubsequences: false)
        return hasValidSyntax(path) && parts.count >= 3 && parts[0] == "skills"
            && parts[2].caseInsensitiveCompare("SKILL.md") != .orderedSame
    }

    private static func hasValidSyntax(_ path: String) -> Bool {
        let parts = PathSyntax.components(path, omittingEmptySubsequences: false)
        return !parts.isEmpty && !PathSyntax.isAbsolute(path)
            && parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
            && !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
    }

    static func ignoreText(paths: [String]) -> String {
        ".DS_Store\n.pensieve-ignore-*\n" + paths.map { path in
            "/" + path.unicodeScalars.map { scalar in
                let text = String(scalar)
                return "\\*?[]!# ".unicodeScalars.contains(scalar) ? "\\" + text : text
            }.joined() + "\n"
        }.joined()
    }

    static func prepare(at root: String, files: FileServiceProtocol, retiring path: String? = nil,
                        log: (String) -> Void = logDroppedPath) throws {
        let receipts = try readReceipts(at: root, files: files)
        _ = try publish(receipts, at: root, files: files, retiring: path, log: log)
    }

    @discardableResult
    static func publish(_ original: Receipts, at root: String, files: FileServiceProtocol,
                        retiring path: String? = nil, log: (String) -> Void = logDroppedPath) throws -> Receipts {
        var receipts = original
        if let path {
            guard canRetire(path) else { throw StoreReceiptError.invalidPath(path) }
            receipts.safe.insert(path)
        }
        // Keep an empty tracked file after dropping its last receipt: concurrent additions must
        // remain ordinary union-merged content edits rather than modify/delete conflicts.
        if receipts.sources[receiptFile] != nil || !receipts.safe.isEmpty || !receipts.unsafe.isEmpty {
            let text = receipts.safe.sorted().map { marker + Data($0.utf8).base64EncodedString() + "\n" }.joined()
            if receipts.sources[receiptFile] != text {
                try files.writeStoreFile(at: root + "/" + receiptFile, content: text, root: root, control: true)
                receipts.sources[receiptFile] = text
            }
        }
        if receipts.sources[".gitattributes"] != attributes {
            try files.writeStoreFile(at: root + "/.gitattributes", content: attributes, root: root, control: true)
            receipts.sources[".gitattributes"] = attributes
        }
        for path in receipts.unsafe.sorted() { log(path) }
        try publishIgnore(at: root, files: files)
        return receipts
    }

    private static func publishIgnore(at root: String, files: FileServiceProtocol) throws {
        // A folder is user data. Keep it in place; staging uses generated rules in metadata.
        let ignore = root + "/.gitignore"
        let type = try files.entryTypeWithoutFollowingLinks(at: ignore)
        if type == .directory { return }
        guard type != .symlink else { throw StoreReceiptError.unreadable(ignore) }
        if let data = try? files.readRegularFileData(at: ignore, maximumBytes: 1_048_576, containedIn: root),
           data == Data(".DS_Store\n".utf8) { return }
        do {
            try files.writeStoreFile(at: ignore, content: ".DS_Store\n", root: root, control: true)
        } catch {
            // rename itself refuses a folder that arrived after the final type check.
            guard (try? files.entryTypeWithoutFollowingLinks(at: ignore)) == .directory else { throw error }
        }
    }

    private static func logDroppedPath(_ path: String) {
        os_log("Dropped unsafe retirement receipt: %{public}@",
               log: OSLog(subsystem: "com.jaredatch.pensieve", category: "sync"), type: .info, path)
    }
}
