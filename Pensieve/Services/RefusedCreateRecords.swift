import Foundation

/// This Mac's collision identities, folderless peer overlays and owed retirements, never synced.
/// Rows keep the metadata; this file only identifies which rows and peer slugs need protection.
struct RefusedCreateRecords {
    static let currentSchemaVersion = 1

    struct Held: Codable {
        let slug: String
        let createdAt: String
        let intentMove: ManifestLocalIntentMove?
    }

    struct RetirementIntent: Codable {
        let machineID: String
        let skillSlug: String
        let platformRaw: String
        let projectKey: String?
    }

    struct RetirementFields: Codable {
        let memberships: [String]
        let intents: [RetirementIntent]
    }

    struct CategoryRename: Codable {
        let old: String
        let new: String
    }

    struct Retirement: Codable {
        let slug: String
        let fields: RetirementFields?
        let categoryRenames: [CategoryRename]
    }

    struct Record: Codable {
        var schemaVersion = currentSchemaVersion
        var held: [Held] = []
        var preserved: [String] = []
        var retirements: [Retirement] = []
    }

    enum ReadError: Error {
        case unreadable
        case unsupportedSchema
    }

    let path: String
    let files: FileServiceProtocol

    fileprivate struct SchemaProbe: Decodable {
        let version: Double
    }

    func read() throws -> Record {
        guard exists else { return Record() }
        let data: Data
        do { data = try files.readData(at: path) } catch { throw ReadError.unreadable }
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(SchemaProbe.self, from: data) else { throw ReadError.unreadable }
        // Probe before decoding the shape, including versions too large to fit in an Int.
        guard probe.version <= Double(Self.currentSchemaVersion) else { throw ReadError.unsupportedSchema }
        guard let record = try? decoder.decode(Record.self, from: data), record.schemaVersion == Self.currentSchemaVersion,
              record.held.allSatisfy({ SkillStore.isPathSafeSlug($0.slug) && ManifestService.parseDate($0.createdAt) != nil }),
              record.preserved.allSatisfy(SkillStore.isPathSafeSlug),
              record.retirements.allSatisfy({ SkillStore.isPathSafeSlug($0.slug) }) else { throw ReadError.unreadable }
        return record
    }

    func write(_ record: Record) throws {
        // A failed restore must never make the next edit downgrade a future file.
        do { _ = try read() } catch ReadError.unreadable { /* Replace corrupt bytes from current state. */ }
        if record.held.isEmpty && record.preserved.isEmpty && record.retirements.isEmpty && !exists { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(record)
        guard let text = String(data: encoded, encoding: .utf8) else { throw ReadError.unreadable }
        if files.directoryExists(at: path) { try files.deleteDirectory(at: path) }
        try files.writeFile(at: path, content: text)
    }

    static func writtenDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private var exists: Bool {
        files.fileExists(at: path) || files.directoryExists(at: path) || files.isSymlink(at: path)
    }
}

private extension RefusedCreateRecords.Held {
    enum CodingKeys: String, CodingKey {
        case slug, createdAt = "created_at", intentMove = "intent_move"
    }
}

private extension RefusedCreateRecords.Record {
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", held, preserved, retirements
    }
}

private extension RefusedCreateRecords.SchemaProbe {
    enum CodingKeys: String, CodingKey { case version = "schema_version" }
}

extension RefusedCreateRecords.Record {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        held = try values.decode([RefusedCreateRecords.Held].self, forKey: .held)
        preserved = try values.decode([String].self, forKey: .preserved)
        retirements = try values.decodeIfPresent([RefusedCreateRecords.Retirement].self, forKey: .retirements) ?? []
    }
}

private extension RefusedCreateRecords.Retirement {
    enum CodingKeys: String, CodingKey { case slug, fields, categoryRenames = "category_renames" }
}

private extension RefusedCreateRecords.RetirementIntent {
    enum CodingKeys: String, CodingKey {
        case machineID = "machine_id", skillSlug = "skill_slug", platformRaw = "platform", projectKey = "project_key"
    }
}
