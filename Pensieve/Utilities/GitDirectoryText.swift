import Foundation

/// Bounded Git control-text reads and syntax shared by HEAD reads and writable-metadata admission.
/// Callers retain their own directory, containment, permission and volume checks.
enum GitDirectoryText {
    static func read(at path: String, fileService: FileServiceProtocol, maximumBytes: Int = 64 * 1_024) throws -> String {
        let data = try fileService.readRegularFileData(at: path, maximumBytes: maximumBytes)
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return text
    }

    static func directory(_ text: String, relativeTo root: String) throws -> String {
        guard text.hasPrefix("gitdir: ") else { throw CocoaError(.fileReadCorruptFile) }
        let target = trimLineEndings(String(text.dropFirst(8)))
        guard !target.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return resolve(target, relativeTo: root)
    }

    static func resolve(_ path: String, relativeTo root: String) -> String {
        PathSyntax.isAbsolute(path) ? path : root + "/" + path
    }

    static func trimLineEndings(_ text: String) -> String {
        var result = text
        while let last = result.unicodeScalars.last, last == "\n" || last == "\r" {
            result.unicodeScalars.removeLast()
        }
        return result
    }
}

/// Git callers choose whether uppercase input is permitted; accepted IDs use one lowercase spelling.
enum GitObjectID {
    enum CasePolicy { case lowercase, either }

    static func parse(_ candidate: String, length: Int? = nil, casePolicy: CasePolicy) -> String? {
        let count = candidate.utf8.count
        guard count == 40 || count == 64, length == nil || length == count,
              candidate.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0)
                  || (casePolicy == .either && (65...70).contains($0)) }) else { return nil }
        return candidate.lowercased()
    }
}
