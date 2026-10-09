import Foundation

enum StoreReceiptError: LocalizedError {
    case unreadable(String)
    case invalidPath(String)

    var errorDescription: String? {
        switch self {
        case let .unreadable(path): return "Sync stopped because retirement receipts at \(path) cannot be read exactly."
        case let .invalidPath(path): return "Sync stopped because a retirement receipt names an unsafe store path: \(path)."
        }
    }
}

/// Receipts live separately from the control files older builds regenerate. Only metadata ignore
/// rules consume them; root .gitignore and .gitattributes retain the older build's exact constants.
enum StoreIgnoreRules {
    static let receiptFile = ".pensieve-retired-paths"
    private static let marker = "# Pensieve retired path: "
    private static let attributes = "manifest/categories/*.yaml merge=union\n"
        + "manifest/scenarios/*.yaml merge=union\nmanifest/projects.yaml merge=union\n"

    static func retiredPaths(at root: String, files: FileServiceProtocol) throws -> [String] {
        var paths: [String] = []
        // Read the unpublished predecessor's comments exactly too, then migrate them on preparation.
        for source in [".gitattributes", receiptFile] {
            let full = root + "/" + source
            guard try files.entryTypeWithoutFollowingLinks(at: full) != nil else { continue }
            let data = try files.readRegularFileData(at: full, maximumBytes: 1_048_576, containedIn: root)
            guard let text = String(data: data, encoding: .utf8) else { throw StoreReceiptError.unreadable(full) }
            for line in text.split(separator: "\n") where line.hasPrefix(marker) {
                guard let data = Data(base64Encoded: String(line.dropFirst(marker.count))),
                      let path = String(data: data, encoding: .utf8), isRetirable(path) else {
                    throw StoreReceiptError.invalidPath(String(line))
                }
                paths.append(path)
            }
        }
        return Array(Set(paths)).sorted()
    }

    /// Retirement admits relative paths with nonempty, nontraversing, noncontrol components.
    private static func isRetirable(_ path: String) -> Bool {
        let parts = PathSyntax.components(path, omittingEmptySubsequences: false)
        return !parts.isEmpty && !PathSyntax.isAbsolute(path)
            && parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
            && !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
    }

    static func ignoreText(paths: [String]) -> String {
        ".DS_Store\n" + paths.map { path in
            "/" + path.unicodeScalars.map { scalar in
                let text = String(scalar)
                return "\\*?[]!# ".unicodeScalars.contains(scalar) ? "\\" + text : text
            }.joined() + "\n"
        }.joined()
    }

    static func prepare(at root: String, files: FileServiceProtocol, retiring path: String? = nil) throws {
        var paths = try retiredPaths(at: root, files: files)
        if let path {
            guard isRetirable(path) else { throw StoreReceiptError.invalidPath(path) }
            paths.append(path)
        }
        paths = Array(Set(paths)).sorted()
        if !paths.isEmpty {
            let receipts = paths.map { marker + Data($0.utf8).base64EncodedString() + "\n" }.joined()
            try files.writeFile(at: root + "/" + receiptFile, content: receipts)
        }
        try files.writeFile(at: root + "/.gitattributes", content: attributes)
        // A folder is user data. Keep it in place; staging uses generated rules in metadata.
        let ignore = root + "/.gitignore"
        let type = try? files.entryTypeWithoutFollowingLinks(at: ignore)
        if type == .regular {
            // A fresh file restores readable permissions even if the remote file had mode 000.
            let temporary = root + "/.pensieve-ignore-" + UUID().uuidString
            defer { try? files.deleteFile(at: temporary) }
            try files.writeFile(at: temporary, content: ".DS_Store\n")
            try files.replaceItem(at: ignore, with: temporary)
        } else if type != .directory {
            try files.writeFile(at: ignore, content: ".DS_Store\n")
        }
    }
}
