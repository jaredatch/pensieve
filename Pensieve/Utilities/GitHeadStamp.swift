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
            let head = try readText(at: git + "/HEAD")
            guard head.hasPrefix("ref:") else { return Self.looseOID(head, length: length).map(State.resolved) ?? .unreadable }
            let ref = String(head.dropFirst(4)).trimmingCharacters(in: Self.gitWhitespace)
            guard Self.validRef(ref) else { return .unreadable }
            // These namespaces belong to a worktree; ordinary branch refs belong to commondir.
            let privateRef = ["refs/bisect/", "refs/worktree/", "refs/rewritten/"].contains { PathSyntax.hasPrefix(ref, $0) }
            let directory = privateRef ? git : common
            let path = directory + "/" + ref
            let type = try fileService.entryTypeWithoutFollowingLinks(at: path)
            // A symlink can name a Git ref chain even when its filesystem target is missing.
            if type == .symlink || type == .other { return .unreadable }
            if type == .regular {
                // A symbolic-ref chain is intentionally unresolved: callers must ingest first.
                return Self.looseOID(try readText(at: path), length: length).map(State.resolved) ?? .unreadable
            }
            return try packedState(ref: ref, directory: common, length: length)
        } catch { return .unreadable }
    }

    /// Small pointers and refs get 64 KiB, config 1 MiB, and packed refs 16 MiB.
    /// A special node, link, invalid UTF-8 or oversized file leaves HEAD unresolved.
    private func readText(at path: String, maximumBytes: Int = 64 * 1_024) throws -> String {
        let data = try fileService.readRegularFileData(at: path, maximumBytes: maximumBytes)
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return text
    }

    private func metadataDirectory(_ entry: String, root: String) throws -> String {
        if try fileService.directoryExistsFollowingLinks(at: entry) { return entry }
        let path = try GitDirectoryText.directory(try readText(at: entry), relativeTo: root)
        guard try fileService.directoryExistsFollowingLinks(at: path) else { throw CocoaError(.fileNoSuchFile) }
        return path
    }

    private func commonDirectory(_ git: String) throws -> String {
        guard try fileService.entryExistsWithoutFollowingLinks(at: git + "/commondir") else { return git }
        let target = GitDirectoryText.trimLineEndings(try readText(at: git + "/commondir"))
        guard !target.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let path = Self.path(target, relativeTo: git)
        guard try fileService.directoryExistsFollowingLinks(at: path) else { throw CocoaError(.fileNoSuchFile) }
        return path
    }

    private func objectIDLength(common: String) throws -> Int {
        let path = common + "/config"
        guard try fileService.entryExistsWithoutFollowingLinks(at: path) else { return 40 }
        return try GitRepositoryFormat.objectIDLength(readText(at: path, maximumBytes: 1_024 * 1_024))
    }

    private func packedState(ref: String, directory: String, length: Int) throws -> State {
        let path = directory + "/packed-refs"
        guard try fileService.entryExistsWithoutFollowingLinks(at: path) else { return .unborn }
        let bytes = Array(try readText(at: path, maximumBytes: 16 * 1_024 * 1_024).utf8)
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
        // Git treats a search miss as an unborn branch, including names with extra separators.
        // Fatal packed-file corruption has already failed in packedRecords.
        return .unborn
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

    /// Git searches by byte position. Unequal record lengths and duplicate ref names can
    /// select a different OID than either a first match or a record-midpoint binary search.
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

/// Git 2.54's repository-format admission. Includes are not followed during Git's format scan.
private struct GitRepositoryFormat {
    var version = -1
    var length = 40
    var unknown = false
    var v1Only = false
    var refStorage = "files"
    var compatibility = false

    static func objectIDLength(_ config: String) throws -> Int {
        var format = Self()
        for (key, value) in try entries(config) {
            if key == "core.repositoryformatversion" {
                format.version = try integer(value)
            } else if key.hasPrefix("extensions.") {
                try format.extensionValue(String(key.dropFirst(11)), value: value)
            }
        }
        guard format.version <= 1,
              !(format.version == 0 && format.v1Only),
              !(format.version >= 1 && format.unknown) else { throw CocoaError(.fileReadUnsupportedScheme) }
        // Git discards extension settings only for its -1 sentinel, absent or explicitly set.
        if format.version == -1 { return 40 }
        guard format.refStorage == "files", !format.compatibility else { throw CocoaError(.fileReadUnsupportedScheme) }
        return format.length
    }

    private mutating func extensionValue(_ key: String, value: String?) throws {
        v1Only = v1Only || ["objectformat", "refstorage", "compatobjectformat", "relativeworktrees", "noop-v1"].contains(key)
        switch key {
        case "objectformat", "compatobjectformat":
            guard let value, ["sha1", "sha256"].contains(value) else { throw CocoaError(.fileReadCorruptFile) }
            if key == "objectformat" { length = value == "sha1" ? 40 : 64 } else { compatibility = true }
        case "refstorage":
            guard let value, ["files", "reftable"].contains(value) else { throw CocoaError(.fileReadCorruptFile) }
            refStorage = value
        case "worktreeconfig", "preciousobjects", "relativeworktrees":
            try Self.validateBoolean(value)
        case "partialclone":
            guard value != nil else { throw CocoaError(.fileReadCorruptFile) }
        case "noop", "noop-v1": break
        default: unknown = true
        }
    }

    private static func validateBoolean(_ value: String?) throws {
        if let value, !["", "true", "yes", "on", "false", "no", "off"].contains(value.lowercased()) {
            _ = try integer(value)
        }
    }

    private static func integer(_ value: String?) throws -> Int {
        guard let value else { throw CocoaError(.fileReadCorruptFile) }
        return try value.withCString { start in
            var end: UnsafeMutablePointer<CChar>?
            let number = strtoll(start, &end, 0)
            guard let end, end != start else { throw CocoaError(.fileReadCorruptFile) }
            let units: [String: Int64] = ["": 1, "k": 1024, "m": 1024 * 1024, "g": 1024 * 1024 * 1024]
            guard let unit = units[String(cString: end).lowercased()] else { throw CocoaError(.fileReadCorruptFile) }
            let (result, overflow) = number.multipliedReportingOverflow(by: unit)
            guard !overflow, let result = Int32(exactly: result) else { throw CocoaError(.fileReadCorruptFile) }
            return Int(result)
        }
    }

    private static func entries(_ config: String) throws -> [(String, String?)] {
        var section = ""
        var entries: [(String, String?)] = []
        for logical in configLines(config) {
            var line = String(logical.unicodeScalars.drop(while: whitespace.contains))
            if line.hasPrefix("[") {
                guard let range = line.range(of: #"^\[[A-Za-z0-9.-]+([ \t]+"([^"\\]|\\.)*")?\]"#,
                                             options: .regularExpression) else { throw CocoaError(.fileReadCorruptFile) }
                let header = String(line[range].dropFirst().dropLast())
                section = header.replacingOccurrences(of: #"[ \t]+"(.*)"$"#, with: ".$1", options: .regularExpression)
                    .lowercased()
                line = String(line[range.upperBound...].unicodeScalars.drop(while: whitespace.contains))
            }
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            guard let keyRange = line.range(of: #"^[A-Za-z][A-Za-z0-9-]*"#, options: .regularExpression) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let key = String(line[keyRange]).lowercased()
            let rest = String(line[keyRange.upperBound...].drop { $0 == " " || $0 == "\t" })
            let value: String?
            if rest.isEmpty { value = nil } else {
                guard rest.hasPrefix("=") else { throw CocoaError(.fileReadCorruptFile) }
                value = try configValue(String(rest.dropFirst()))
            }
            entries.append((section + "." + key, value))
        }
        return entries
    }

    private static let whitespace = CharacterSet(charactersIn: " \t\r\n")

    private static func configLines(_ config: String) -> [String] {
        var lines: [String] = [], line = ""
        var quoted = false, escaped = false, comment = false, value = false
        for character in config.replacingOccurrences(of: "\r\n", with: "\n") {
            if character == "\n" {
                if escaped && !comment && value {
                    line.removeLast()
                } else {
                    lines.append(line)
                    line = ""
                    quoted = false
                    comment = false
                    value = false
                }
                escaped = false
                continue
            }
            line.append(character)
            if comment { continue }
            if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" {
                quoted.toggle()
            } else if !quoted && character == "=" { value = true
            } else if !quoted && (character == "#" || character == ";") { comment = true }
        }
        lines.append(line)
        return lines
    }

    private static func configValue(_ text: String) throws -> String {
        var quoted = false, escaped = false, result = "", whitespace = ""
        for character in text {
            if escaped {
                let escapes: [Character: String] = ["n": "\n", "t": "\t", "b": "\u{8}", "\\": "\\", "\"": "\""]
                guard let value = escapes[character] else { throw CocoaError(.fileReadCorruptFile) }
                result += whitespace + value
                whitespace = ""
                escaped = false
            } else if character == "\\" { escaped = true } else if character == "\"" {
                result += whitespace
                whitespace = ""
                quoted.toggle()
            } else if !quoted && (character == "#" || character == ";") { break
            } else if !quoted && character.unicodeScalars.allSatisfy(Self.whitespace.contains) {
                if !result.isEmpty { whitespace += String(character) }
            } else {
                result += whitespace + String(character)
                whitespace = ""
            }
        }
        guard !quoted else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }
}
