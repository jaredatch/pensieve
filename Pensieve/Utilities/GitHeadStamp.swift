import Foundation

/// Reads repository state through FileService without spawning git. An absent repository or an
/// unborn branch cannot have received an outside pull; unreadable repository metadata can have.
struct GitHeadStamp {
    enum State: Equatable {
        case noRepository, unborn, unreadable
        case resolved(String)

        var oid: String? {
            if case let .resolved(value) = self { return value }
            return nil
        }
    }

    private let fileService: FileServiceProtocol

    init(fileService: FileServiceProtocol = FileService()) {
        self.fileService = fileService
    }

    func read(root: String) -> String? { state(root: root).oid }

    func state(root: String) -> State {
        let git = root + "/.git"
        do {
            guard try fileService.entryExistsWithoutFollowingLinks(at: git) else { return .noRepository }
            let head = try fileService.readFile(at: git + "/HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
            guard head.hasPrefix("ref: ") else { return Self.oid(from: head).map(State.resolved) ?? .unreadable }
            let ref = String(head.dropFirst(5))
            guard PathSyntax.hasPrefix(ref, "refs/heads/"), !ref.contains(".."),
                  !ref.contains("\\"), !ref.contains(where: \.isWhitespace) else { return .unreadable }
            if try fileService.entryExistsWithoutFollowingLinks(at: git + "/" + ref) {
                let value = try fileService.readFile(at: git + "/" + ref).trimmingCharacters(in: .whitespacesAndNewlines)
                return Self.oid(from: value).map(State.resolved) ?? .unreadable
            }
            if try fileService.entryExistsWithoutFollowingLinks(at: git + "/packed-refs") {
                let packed = try fileService.readFile(at: git + "/packed-refs")
                for line in packed.split(separator: "\n") where line.hasSuffix(" " + ref) {
                    return Self.oid(from: String(line.split(separator: " ")[0])).map(State.resolved) ?? .unreadable
                }
            }
            return .unborn
        } catch { return .unreadable }
    }

    private static func oid(from candidate: String) -> String? {
        guard candidate.count == 40 || candidate.count == 64,
              candidate.allSatisfy(\.isHexDigit) else { return nil }
        return candidate
    }
}
