import Foundation

struct DeployStateRecord: Codable, Equatable {
    let slug: String
    let platform: String
    let scope: String
    let projectIdentityKey: String?
    let artifactPath: String
    let recordedAt: String

    /// Keyless deployments are local project facts, named by their checkout path in local readers.
    var projectReference: String {
        if let projectIdentityKey { return projectIdentityKey }
        guard let platform = PlatformTarget(rawValue: platform), platform.supportsProjectScope else { return artifactPath }
        let suffix = platform == .cursor
            ? DeployPaths(skillsDirectory: "", userSkillsDirectories: [:],
                cursorUserRulesDirectory: "").cursorPath(directoryName: slug, projectPath: "")
            : DeployPaths(skillsDirectory: "", userSkillsDirectories: [:],
                cursorUserRulesDirectory: "").linkPath(directoryName: slug, platform: platform, projectPath: "")
        guard artifactPath.hasSuffix(suffix) else { return artifactPath }
        let path = String(artifactPath.dropLast(suffix.count))
        return path.isEmpty ? "/" : path
    }
}

struct DeployState: Codable, Equatable {
    var schemaVersion: Int
    var records: [DeployStateRecord]
}

enum DeployStateError: Error, Equatable {
    case unreadable(String)
    case unsupportedSchema(Int)
}

final class DeployStateStore {
    static let currentSchemaVersion = 1

    let fileService: FileServiceProtocol
    let appSupportDir: String

    private var statePath: String { appSupportDir + "/deploy-state.json" }
    private var lockPath: String { appSupportDir + "/deploy-state.lock" }

    init(
        fileService: FileServiceProtocol,
        appSupportDir: String,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileService = fileService
        self.appSupportDir = appSupportDir
        _ = now
    }

    func read() throws -> DeployState {
        guard fileService.fileExists(at: statePath)
                || fileService.directoryExists(at: statePath)
                || fileService.isSymlink(at: statePath)
        else {
            return DeployState(schemaVersion: Self.currentSchemaVersion, records: [])
        }

        let text: String
        do {
            text = try fileService.readFile(at: statePath)
        } catch {
            throw DeployStateError.unreadable(statePath)
        }

        guard let data = text.data(using: .utf8) else {
            throw DeployStateError.unreadable(statePath)
        }

        let schemaVersion: Int
        if let probed = try? decodedSchemaVersion(from: data) {
            schemaVersion = probed
        } else if let wide = try? decoder.decode(WideSchemaProbe.self, from: data),
                  wide.schemaVersion > Double(Self.currentSchemaVersion) {
            // A present NUMERIC schema_version too large for Int is a FUTURE schema, not corrupt
            // bytes — misclassifying it as .unreadable would let the replaceAll healer overwrite a
            // newer-schema file (the frozen never-downgrade rule; 16.1 Layer-2 P2).
            throw DeployStateError.unsupportedSchema(Int.max)
        } else {
            throw DeployStateError.unreadable(statePath)
        }

        guard schemaVersion <= Self.currentSchemaVersion else {
            throw DeployStateError.unsupportedSchema(schemaVersion)
        }

        guard let decoded = try? decoder.decode(DeployState.self, from: data) else {
            throw DeployStateError.unreadable(statePath)
        }

        return normalized(decoded)
    }

    /// Every recorded artifact path, read once. An absent state file is the empty set; anything the
    /// store refuses to read is rethrown as its own error — `.unreadable` (corrupt bytes; the launch
    /// backfill rebuilds them) or `.unsupportedSchema` (a newer file; never downgraded).
    func recordedArtifactPaths() throws -> Set<String> {
        guard stateFileExists else { return [] }
        return Set(try read().records.map(\.artifactPath))
    }

    func upsert(_ record: DeployStateRecord) throws {
        try withLock {
            var state = try read()
            state.records.removeAll { $0.artifactPath == record.artifactPath }
            state.records.append(record)
            try write(state)
        }
    }

    @discardableResult
    func remove(artifactPath: String) throws -> Bool {
        try remove(artifactPaths: [artifactPath])
    }

    @discardableResult
    func remove(artifactPaths: Set<String>) throws -> Bool {
        guard !artifactPaths.isEmpty else { return false }
        return try withLock {
            guard stateFileExists else { return false }
            var state = try read()
            guard state.records.contains(where: { artifactPaths.contains($0.artifactPath) }) else { return false }
            state.records.removeAll { artifactPaths.contains($0.artifactPath) }
            try write(state)
            return true
        }
    }

    func replaceAll(_ records: [DeployStateRecord]) throws {
        try withLock {
            do {
                _ = try read()
            } catch DeployStateError.unreadable {
                // Backfill healer: corrupt current-schema bytes may be replaced from the derived truth.
            } catch {
                throw error
            }
            try write(DeployState(schemaVersion: Self.currentSchemaVersion, records: records))
        }
    }
}

private extension DeployStateStore {
    struct SchemaProbe: Codable {
        let schemaVersion: Int
    }

    /// Fallback probe for a numeric schema_version that overflows Int (decodes as Double).
    struct WideSchemaProbe: Codable {
        let schemaVersion: Double
    }

    var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    var stateFileExists: Bool {
        fileService.fileExists(at: statePath)
            || fileService.directoryExists(at: statePath)
            || fileService.isSymlink(at: statePath)
    }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        guard let lock = SyncLock.acquire(at: lockPath) else {
            throw DeployStateError.unreadable(lockPath)
        }
        defer { lock.release() }
        return try body()
    }

    func write(_ state: DeployState) throws {
        let encoded = try encoder.encode(normalized(state))
        guard let text = String(data: encoded, encoding: .utf8) else {
            throw DeployStateError.unreadable(statePath)
        }
        try fileService.writeFile(at: statePath, content: text)
    }

    func decodedSchemaVersion(from data: Data) throws -> Int {
        try decoder.decode(SchemaProbe.self, from: data).schemaVersion
    }

    func normalized(_ state: DeployState) -> DeployState {
        DeployState(
            schemaVersion: state.schemaVersion,
            records: state.records.sorted { lhs, rhs in
                if lhs.artifactPath != rhs.artifactPath { return lhs.artifactPath < rhs.artifactPath }
                return lhs.recordedAt < rhs.recordedAt
            }
        )
    }
}
