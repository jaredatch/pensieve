import Foundation
import CryptoKit

struct CursorRemovalFingerprint: Codable, Equatable {
    let digest: String
    let byteCount: Int

    init(content: String) {
        let bytes = Data(content.utf8)
        digest = Self.digest(bytes)
        byteCount = bytes.count
    }

    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

struct WaitingRemoval: Codable, Equatable {
    var id = UUID()
    let source: String
    let projectPath: String
    let projectName: String
    let projectIdentityKey: String?
    let artifactPath: String
    let platform: PlatformTarget
    let slug: String
    let legacyFingerprint: CursorRemovalFingerprint?

    var isValid: Bool {
        guard projectPath.hasPrefix("/"), platform.supportsProjectScope,
              (try? LinkService.validatePathComponent(slug)) != nil, !source.isEmpty else { return false }
        let expected = platform == .cursor
            ? DeployPaths(skillsDirectory: "", userSkillsDirectories: [:],
                cursorUserRulesDirectory: "").cursorPath(directoryName: slug, projectPath: projectPath)
            : DeployPaths(skillsDirectory: "", userSkillsDirectories: [:],
                cursorUserRulesDirectory: "").linkPath(directoryName: slug, platform: platform, projectPath: projectPath)
        guard artifactPath == expected else { return false }
        if let fingerprint = legacyFingerprint {
            return platform == .cursor && fingerprint.byteCount >= 0 && fingerprint.digest.utf8.count == 64
                && fingerprint.digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        return true
    }
}

enum WaitingRemovalError: LocalizedError {
    case unreadable(String)
    case unsupportedSchema
    case locked
    case invalidEntry(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let path): "Waiting removals paused: couldn't read \(path). The file was kept."
        case .unsupportedSchema: "Waiting removals paused: update Pensieve to read this newer waiting-removal file."
        case .locked: "Waiting removals paused: their local store is busy. Try again."
        case .invalidEntry(let path): "Couldn't save waiting cleanup: rejected the entry at \(path)."
        }
    }
}

protocol WaitingRemovalStoring {
    func read() throws -> [WaitingRemoval]
    func add(_ entries: [WaitingRemoval]) throws
    func retire(ids: Set<UUID>) throws
}

/// Durable cleanup intent, separate from rebuildable deployment state. Only append and identity
/// retirement mutate it. A refused read never supplies an empty replacement to a writer.
final class WaitingRemovalStore: WaitingRemovalStoring {
    private struct State: Codable {
        var schemaVersion = 1
        var removals: [WaitingRemoval] = []
    }

    private struct Schema: Decodable { let schemaVersion: Double }
    private let fileService: FileServiceProtocol
    private let path: String
    private let lockPath: String

    init(fileService: FileServiceProtocol, appSupportDir: String) {
        self.fileService = fileService
        path = appSupportDir + "/waiting-removals.json"
        lockPath = appSupportDir + "/waiting-removals.lock"
    }

    func read() throws -> [WaitingRemoval] {
        // An absent store needs no lock-file creation, including in a fresh app-support folder.
        guard try fileService.entryTypeWithoutFollowingLinks(at: path) != nil else { return [] }
        return try withLock { try load().removals }
    }

    func add(_ entries: [WaitingRemoval]) throws {
        guard !entries.isEmpty else { return }
        try withLock {
            var state = try load()
            let initialCount = state.removals.count
            for entry in entries {
                guard entry.isValid else { throw WaitingRemovalError.invalidEntry(entry.artifactPath) }
                if !state.removals.contains(where: { $0.source == entry.source && $0.artifactPath == entry.artifactPath }) {
                    state.removals.append(entry)
                }
            }
            if state.removals.count != initialCount { try write(state) }
        }
    }

    func retire(ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        try withLock {
            var state = try load()
            guard state.removals.contains(where: { ids.contains($0.id) }) else { return }
            state.removals.removeAll { ids.contains($0.id) }
            try write(state)
        }
    }

    private func load() throws -> State {
        do {
            guard let type = try fileService.entryTypeWithoutFollowingLinks(at: path) else { return State() }
            guard type == .regular else { throw WaitingRemovalError.unreadable(path) }
            let bytes = try fileService.readData(at: path)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let schema = try decoder.decode(Schema.self, from: bytes).schemaVersion
            guard schema <= 1 else { throw WaitingRemovalError.unsupportedSchema }
            guard schema == 1 else { throw WaitingRemovalError.unreadable(path) }
            let state = try decoder.decode(State.self, from: bytes)
            guard state.removals.allSatisfy(\.isValid), Set(state.removals.map(\.id)).count == state.removals.count else {
                throw WaitingRemovalError.unreadable(path)
            }
            return state
        } catch let error as WaitingRemovalError { throw error } catch {
            throw WaitingRemovalError.unreadable(path)
        }
    }

    private func write(_ state: State) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(state)
        guard let content = String(data: bytes, encoding: .utf8) else { throw WaitingRemovalError.unreadable(path) }
        try fileService.writeFile(at: path, content: content)
    }

    private func withLock<Value>(_ operation: () throws -> Value) throws -> Value {
        guard let lock = SyncLock.acquire(at: lockPath) else { throw WaitingRemovalError.locked }
        defer { lock.release() }
        return try operation()
    }
}
