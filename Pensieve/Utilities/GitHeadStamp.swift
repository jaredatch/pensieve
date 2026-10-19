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
        do {
            let entry = root + "/.git"
            guard try fileService.entryExistsWithoutFollowingLinks(at: entry) else { return .noRepository }
            let git = try metadataDirectory(entry, root: root)
            let common = try commonDirectory(git)
            guard try fileService.directoryExistsFollowingLinks(at: common + "/objects"),
                  try fileService.directoryExistsFollowingLinks(at: common + "/refs") else { return .unreadable }
            let length = try objectIDLength(common: common)
            let head = try fileService.readFile(at: git + "/HEAD")
            guard head.hasPrefix("ref:") else { return Self.looseOID(head, length: length).map(State.resolved) ?? .unreadable }
            let ref = String(head.dropFirst(4)).trimmingCharacters(in: Self.gitWhitespace)
            guard Self.validRef(ref) else { return .unreadable }
            // These namespaces belong to a worktree; ordinary branch refs belong to commondir.
            let privateRef = ["refs/bisect/", "refs/worktree/", "refs/rewritten/"].contains { PathSyntax.hasPrefix(ref, $0) }
            let directory = privateRef ? git : common
            let packed = try packedState(ref: ref, directory: common, length: length)
            let path = directory + "/" + ref
            if try fileService.entryExistsWithoutFollowingLinks(at: path) {
                // A symbolic-ref chain is intentionally unresolved: callers must ingest first.
                return Self.looseOID(try fileService.readFile(at: path), length: length).map(State.resolved) ?? .unreadable
            }
            return packed
        } catch { return .unreadable }
    }

    private func metadataDirectory(_ entry: String, root: String) throws -> String {
        if try fileService.directoryExistsFollowingLinks(at: entry) { return entry }
        let text = try fileService.readFile(at: entry)
        guard text.hasPrefix("gitdir: ") else { throw CocoaError(.fileReadCorruptFile) }
        let target = Self.trimLineEndings(String(text.dropFirst(8)))
        guard !target.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let path = Self.path(target, relativeTo: root)
        guard try fileService.directoryExistsFollowingLinks(at: path) else { throw CocoaError(.fileNoSuchFile) }
        return path
    }

    private func commonDirectory(_ git: String) throws -> String {
        guard try fileService.entryExistsWithoutFollowingLinks(at: git + "/commondir") else { return git }
        let target = Self.trimLineEndings(try fileService.readFile(at: git + "/commondir"))
        guard !target.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let path = Self.path(target, relativeTo: git)
        guard try fileService.directoryExistsFollowingLinks(at: path) else { throw CocoaError(.fileNoSuchFile) }
        return path
    }

    private func objectIDLength(common: String) throws -> Int {
        let path = common + "/config"
        guard try fileService.entryExistsWithoutFollowingLinks(at: path) else { return 40 }
        let config = try fileService.readFile(at: path)
        var extensions = false
        for line in config.components(separatedBy: .newlines) {
            let value = line.trimmingCharacters(in: .whitespaces).lowercased()
            if value.hasPrefix("[") { extensions = value == "[extensions]"; continue }
            if extensions, value.range(of: #"^objectformat\s*=\s*\"?sha256\"?\s*([#;].*)?$"#,
                                       options: .regularExpression) != nil { return 64 }
        }
        return 40
    }

    private func packedState(ref: String, directory: String, length: Int) throws -> State {
        let path = directory + "/packed-refs"
        guard try fileService.entryExistsWithoutFollowingLinks(at: path) else { return .unborn }
        let bytes = Array(try fileService.readFile(at: path).utf8)
        if bytes.isEmpty { return .unborn }
        guard bytes.last == 10 else { throw CocoaError(.fileReadCorruptFile) }
        let records = try Self.packedRecords(bytes, length: length)
        let buffer = records.flatMap { $0 }
        if let offset = Self.packedOffset(ref: Array(ref.utf8), buffer: buffer, length: length) {
            let oid = String(bytes: buffer.dropFirst(offset).prefix(length), encoding: .utf8) ?? ""
            guard offset + length < buffer.count, Self.gitWhitespace.contains(Unicode.Scalar(buffer[offset + length])) else {
                return .unreadable
            }
            return Self.exactOID(oid, length: length).map(State.resolved) ?? .unreadable
        }
        // A valid absent branch is unborn; malformed records must not suppress ingestion.
        return records.allSatisfy {
            let line = $0.prefix { $0 != 10 }
            let name = String(bytes: Self.packedName($0, length: length), encoding: .utf8) ?? ""
            return line.count > length + 1 && Self.validRef(name)
                && Self.exactOID((String(bytes: line.prefix(length), encoding: .utf8) ?? ""), length: length) != nil
        } ? .unborn : .unreadable
    }

    private static func packedRecords(_ bytes: [UInt8], length: Int) throws -> [[UInt8]] {
        var lines = bytes.dropLast().split(separator: 10, omittingEmptySubsequences: false).map(Array.init)
        var sorted = false
        if lines.first?.first == 35 {
            let header = String(bytes: lines.removeFirst(), encoding: .utf8) ?? ""
            guard header.hasPrefix("# pack-refs with: ") else { throw CocoaError(.fileReadCorruptFile) }
            sorted = header.dropFirst(18).split(separator: " ").contains("sorted")
        }
        if lines.isEmpty { return [] }
        var records: [[UInt8]] = []
        for line in lines {
            if line.first == 94, !records.isEmpty {
                records[records.count - 1] += line + [10]
            } else {
                if !sorted, line.count < length + 2 { throw CocoaError(.fileReadCorruptFile) }
                records.append(line + [10])
            }
        }
        guard let last = records.last, last.count >= length + 2 else { throw CocoaError(.fileReadCorruptFile) }
        if !sorted {
            records.sort { Self.packedName($0, length: length).lexicographicallyPrecedes(Self.packedName($1, length: length)) }
        }
        return records
    }

    private static func packedName(_ record: [UInt8], length: Int) -> [UInt8] {
        Array(record.dropFirst(length + 1).prefix { $0 != 10 })
    }

    /// Packed files marked sorted are searched by byte position. This also keeps Git's
    /// treatment of malformed records it never visits; peeled lines belong to their record.
    private static func packedOffset(ref: [UInt8], buffer: [UInt8], length: Int) -> Int? {
        var lower = 0, upper = buffer.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            var start = middle
            while start > lower && (buffer[start - 1] != 10 || buffer[start] == 94) { start -= 1 }
            let name = Array(buffer.dropFirst(start + length + 1).prefix { $0 != 10 })
            if name == ref { return start }
            if name.lexicographicallyPrecedes(ref) {
                var next = middle + 1
                while next < upper && (buffer[next - 1] != 10 || buffer[next] == 94) { next += 1 }
                lower = next
            } else { upper = start }
        }
        return nil
    }

    private static let gitWhitespace = CharacterSet(charactersIn: " \t\n\r\u{000B}\u{000C}")

    private static func trimLineEndings(_ text: String) -> String {
        var result = text
        while let last = result.unicodeScalars.last, last == "\n" || last == "\r" {
            result.unicodeScalars.removeLast()
        }
        return result
    }

    private static func path(_ value: String, relativeTo base: String) -> String {
        PathSyntax.isAbsolute(value) ? value : base + "/" + value
    }

    private static func validRef(_ ref: String) -> Bool {
        guard PathSyntax.hasPrefix(ref, "refs/"), !ref.contains(".."), !ref.contains("@{"),
              !ref.hasSuffix("."), !ref.unicodeScalars.contains(where: {
                  $0.value <= 32 || $0.value == 127 || "~^:?*[\\".unicodeScalars.contains($0)
              }) else { return false }
        return PathSyntax.components(ref, omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock")
        }
    }

    private static func looseOID(_ text: String, length: Int) -> String? {
        let token = String(text.unicodeScalars.prefix { $0.value != 0 && !gitWhitespace.contains($0) })
        return exactOID(token, length: length)
    }

    private static func exactOID(_ candidate: String, length: Int) -> String? {
        guard candidate.utf8.count == length,
              candidate.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        return candidate.lowercased()
    }
}
