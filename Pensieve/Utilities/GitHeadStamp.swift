import Foundation

/// Reads a cheap repository-HEAD change stamp through the FileService boundary, without spawning git.
/// An unreadable or unresolved repository returns nil; detached HEADs return the SHA.
struct GitHeadStamp {
    private let fileService: FileServiceProtocol

    init(fileService: FileServiceProtocol = FileService()) {
        self.fileService = fileService
    }

    func read(root: String) -> String? {
        guard let head = try? fileService.readFile(at: root + "/.git/HEAD") else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.hasPrefix("ref: ") else { return Self.oid(from: trimmed) }

        let ref = String(trimmed.dropFirst(5))
        if let sha = try? fileService.readFile(at: root + "/.git/" + ref) {
            return Self.oid(from: sha.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let packed = try? fileService.readFile(at: root + "/.git/packed-refs") {
            for line in packed.split(separator: "\n") where line.hasSuffix(" " + ref) {
                return Self.oid(from: String(line.split(separator: " ")[0]))
            }
        }
        return nil
    }

    private static func oid(from candidate: String) -> String? {
        guard candidate.count == 40 || candidate.count == 64,
              candidate.allSatisfy(\.isHexDigit) else { return nil }
        return candidate
    }
}
