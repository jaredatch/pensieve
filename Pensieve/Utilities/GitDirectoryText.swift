import Foundation

/// Pure Git control-text syntax shared by HEAD reads and writable-metadata admission.
/// Callers retain their own directory, containment, permission and volume checks.
enum GitDirectoryText {
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

    static func parse(_ candidate: String, length: Int, casePolicy: CasePolicy) -> String? {
        guard candidate.utf8.count == length,
              candidate.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0)
                  || (casePolicy == .either && (65...70).contains($0)) }) else { return nil }
        return candidate.lowercased()
    }
}
