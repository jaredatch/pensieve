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
    }
}
