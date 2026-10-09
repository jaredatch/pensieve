import Foundation

/// Retirement receipts travel as comments in the app-authored attributes file. The root ignore is
/// derived output, never a source: a remote's ignore rules or linked bytes cannot control staging.
enum StoreIgnoreRules {
    private static let marker = "# Pensieve retired path: "
    private static let attributes = "manifest/categories/*.yaml merge=union\n"
        + "manifest/scenarios/*.yaml merge=union\nmanifest/projects.yaml merge=union\n"

    static func retiredPaths(at root: String, files: FileServiceProtocol) -> [String] {
        guard let data = try? files.readRegularFileData(at: root + "/.gitattributes", maximumBytes: 1_048_576,
                                                       containedIn: root),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard line.hasPrefix(marker), let data = Data(base64Encoded: String(line.dropFirst(marker.count))),
                  let path = String(data: data, encoding: .utf8), !PathSyntax.isAbsolute(path),
                  !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
            let components = PathSyntax.components(path, omittingEmptySubsequences: false)
            guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
            return path
        }
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
        var paths = retiredPaths(at: root, files: files)
        if let path, !paths.contains(where: { $0 == path }) { paths.append(path) }
        paths = Array(Set(paths)).sorted()
        let receipts = paths.map { marker + Data($0.utf8).base64EncodedString() + "\n" }.joined()
        try files.writeFile(at: root + "/.gitattributes", content: attributes + receipts)
        // A folder is user data. Keep it in place; staging uses the same generated rules in metadata.
        let ignore = root + "/.gitignore"
        let type = try? files.entryTypeWithoutFollowingLinks(at: ignore)
        if type == .regular {
            // A fresh file restores readable permissions even if the remote file had mode 000.
            let temporary = root + "/.pensieve-ignore-" + UUID().uuidString
            defer { try? files.deleteFile(at: temporary) }
            try files.writeFile(at: temporary, content: ignoreText(paths: paths))
            try files.replaceItem(at: ignore, with: temporary)
        } else if type != .directory {
            try files.writeFile(at: ignore, content: ignoreText(paths: paths))
        }
    }
}
