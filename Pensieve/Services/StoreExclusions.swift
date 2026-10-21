import Foundation

/// One policy for local import, staging, daemon cleanliness and incoming-path protection.
enum StoreExclusions {
    private static let directories = ["node_modules", ".env", ".venv"]
    private static let templates = [".env.example", ".env.sample", ".env.template"]
    static let directoryArguments = directories.map { "--exclude=" + $0 + "/" }
    static let directoryPathspecs = directories.map { ":(glob)**/" + $0 + "/**" }

    static func isExcludedDirectory(_ name: Data.SubSequence) -> Bool {
        directories.contains { name.elementsEqual($0.utf8) }
    }

    static func isTemplateFile(_ name: Data.SubSequence) -> Bool {
        templates.contains { name.elementsEqual($0.utf8) }
    }

    static func folderContainingFile(_ path: Data.SubSequence) -> Data? {
        let components = path.split(separator: 0x2F)
        guard let index = components.dropLast().firstIndex(where: isExcludedDirectory) else { return nil }
        return components.prefix(through: index).reduce(into: Data()) { result, component in
            if !result.isEmpty { result.append(0x2F) }
            result.append(contentsOf: component)
        }
    }

    static func isExcludedFile(_ path: Data.SubSequence) -> Bool {
        let components = path.split(separator: 0x2F)
        guard let name = components.last else { return false }
        if components.dropLast().contains(where: isExcludedDirectory) { return true }
        if isTemplateFile(name) { return false }
        return name.elementsEqual(".env".utf8) || name.starts(with: ".env.".utf8)
            || name.elementsEqual(".DS_Store".utf8)
            || (components.count == 1 && name.starts(with: ".pensieve-ignore-".utf8))
    }
}

/// Which untracked entries are invisible to the manifest readers.
enum ManifestReaderPolicy {
    enum EntryKind { case leaf, emptyDirectory }

    /// Reader visibility for a byte path relative to manifest/. Recovery uses the same policy
    /// before decoding Git's untracked names; the flat readers inspect only their immediate child.
    static func ignoresEntry(at relativePath: Data.SubSequence, kind: EntryKind = .leaf) -> Bool {
        let parts = relativePath.split(separator: 0x2F)
        guard let first = parts.first else { return false }
        if kind == .emptyDirectory {
            if parts.count == 1 {
                return ["categories", "skills", "deploys"].contains { first.elementsEqual($0.utf8) }
            }
            guard first.elementsEqual("deploys".utf8), parts.count == 2,
                  let machine = String(bytes: parts[1], encoding: .utf8),
                  let uuid = UUID(uuidString: machine) else { return false }
            return machine == uuid.uuidString
        }
        if first.elementsEqual("categories".utf8) || first.elementsEqual("skills".utf8) {
            return parts.count > 1 && !parts[1].suffix(5).elementsEqual(".yaml".utf8)
        }
        if first.elementsEqual("deploys".utf8) {
            guard parts.count > 1 else { return false }
            return StoreExclusions.isExcludedFile(relativePath)
                || parts.dropFirst().contains(where: StoreExclusions.isExcludedDirectory)
        }
        return !first.elementsEqual("manifest.yaml".utf8) && !first.elementsEqual("projects.yaml".utf8)
    }

}
