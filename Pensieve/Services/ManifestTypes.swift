import Foundation

// MARK: - Records

struct InstalledOrigin: Codable, Equatable {
    var repo: String
    var path: String
    var ref: String
    var installedCommit: String
    var installedTree: String
    var contentHash: String
    var installedAt: Date
    var updatedAt: Date

    static let empty = InstalledOrigin(
        repo: "",
        path: "",
        ref: "",
        installedCommit: "",
        installedTree: "",
        contentHash: "",
        installedAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

enum SkillOrigin: Equatable {
    case authored
    case imported(from: String)
    case installed(InstalledOrigin)
}

struct SkillOverlay: Equatable { var slug: String; var createdAt: Date; var scope: SkillScope; var tags: [String]
    var cursor: CursorAdapterConfig?; var agents: [String]; var origin: SkillOrigin }
struct CategoryRecord: Equatable { var name: String; var projectKeys: [String]; var skillSlugs: [String] }
struct ProjectIdentityRecord: Equatable { var identityKey: String; var identityKind: String; var name: String }
struct DeployIntentRecord: Equatable {
    var machineID: String
    var skillSlug: String
    var platformRaw: String
    var projectKey: String?
}

struct ManifestSnapshot: Equatable {
    var schemaVersion: Int
    var categories: [CategoryRecord]
    var projects: [ProjectIdentityRecord]
    var skills: [SkillOverlay]
    var deployIntents: [DeployIntentRecord]

    init(schemaVersion: Int,
         categories: [CategoryRecord],
         projects: [ProjectIdentityRecord],
         skills: [SkillOverlay],
         deployIntents: [DeployIntentRecord] = []) {
        self.schemaVersion = schemaVersion
        self.categories = categories
        self.projects = projects
        self.skills = skills
        self.deployIntents = deployIntents
    }
}

enum ManifestError: Error, Equatable {
    case unsupportedSchema(found: Int, supported: Int)
    case corruptManifestFile(String)   // present-but-unparseable → read throws, rebuild bails; never silently dropped
}

protocol ManifestReadWriting {
    func write(_ snapshot: ManifestSnapshot, toRoot root: String) throws
    func read(fromRoot root: String) throws -> ManifestSnapshot
    func upsertSkillOverlay(_ overlay: SkillOverlay, toRoot root: String) throws
}

extension ManifestReadWriting {
    /// Merge exactly one skill overlay into the current durable snapshot. Reading first is
    /// load-bearing: corrupt/newer trees must fail instead of being silently rebuilt or pruned.
    func upsertSkillOverlay(_ overlay: SkillOverlay, toRoot root: String) throws {
        var snapshot = try read(fromRoot: root)
        try ManifestService.validateSkillSlugs(snapshot.skills)
        try ManifestService.validateSkillSlugs([overlay])
        if let index = snapshot.skills.firstIndex(where: { $0.slug == overlay.slug }) {
            snapshot.skills[index] = overlay
        } else {
            snapshot.skills.append(overlay)
        }
        snapshot.skills.sort { $0.slug < $1.slug }
        try write(snapshot, toRoot: root)
    }
}

extension ManifestService {
    static func isAdmittedIntentComponent(_ value: String) -> Bool {
        guard (1...64).contains(value.utf8.count), value.unicodeScalars.count == value.utf8.count else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 46, 95:
                true
            default:
                false
            }
        }
    }

    static func isCanonicalMachineID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return value == uuid.uuidString
    }

    static func isAdmittedProjectKey(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 512,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        let forbidden = CharacterSet.controlCharacters.union(.newlines)
        return value.unicodeScalars.allSatisfy {
            isYAMLPrintable($0) && !forbidden.contains($0)
        }
    }

    private static func isYAMLPrintable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0D, 0x20...0x7E, 0x85, 0xA0...0xD7FF,
             0xE000...0xFFFD, 0x1_0000...0x10_FFFF:
            true
        default:
            false
        }
    }

    static func validateDeployIntents(_ records: [DeployIntentRecord]) throws {
        var spellingsByUUID: [UUID: String] = [:]
        var slugsByMachine: [String: Set<String>] = [:]
        for record in records {
            guard let uuid = UUID(uuidString: record.machineID) else {
                throw ManifestError.corruptManifestFile("deploys/" + record.machineID)
            }
            if let spelling = spellingsByUUID[uuid], spelling != record.machineID {
                throw ManifestError.corruptManifestFile("deploys/" + record.machineID)
            }
            spellingsByUUID[uuid] = record.machineID
            guard isCanonicalMachineID(record.machineID),
                  isAdmittedIntentComponent(record.skillSlug),
                  SkillStore.isPathSafeSlug(record.skillSlug),
                  isAdmittedIntentComponent(record.platformRaw),
                  record.projectKey.map(isAdmittedProjectKey) ?? true else {
                throw ManifestError.corruptManifestFile(
                    "deploys/" + record.machineID + "/" + record.skillSlug + ".yaml"
                )
            }
            let foldedSlug = record.skillSlug.lowercased()
            var machineSlugs = slugsByMachine[record.machineID, default: []]
            if let existing = machineSlugs.first(where: { $0.lowercased() == foldedSlug }),
               existing != record.skillSlug {
                throw ManifestError.corruptManifestFile(
                    "deploys/" + record.machineID + "/" + record.skillSlug + ".yaml"
                )
            }
            machineSlugs.insert(record.skillSlug)
            slugsByMachine[record.machineID] = machineSlugs
        }
    }

    /// Skill slugs become filenames in the full-snapshot writer. Reject only a **path-unsafe** slug
    /// (traversal, hidden, or control characters — the values that could escape `skills/` as a
    /// filename or break the YAML scalar) or a duplicate. A path-safe but non-canonical slug
    /// (`PDF_Tools`, `My.Skill`) is a legitimate imported/hand-placed skill and must NOT brick the
    /// write — the earlier canonical-strict guard did, corrupting the whole store on one such row.
    /// Duplicate detection is **case-folded**: `PDF_Tools` and `pdf_tools` are distinct Strings but
    /// map to the same `skills/<slug>.yaml` file on a case-insensitive volume (default APFS), so
    /// admitting both would silently drop one skill on write — surface it as corruption instead.
    /// (PLAN-19 security review.)
    static func validateSkillSlugs(_ overlays: [SkillOverlay]) throws {
        var seen = Set<String>()
        for overlay in overlays {
            guard SkillStore.isPathSafeSlug(overlay.slug),
                  seen.insert(overlay.slug.lowercased()).inserted else {
                throw ManifestError.corruptManifestFile("skills/" + overlay.slug + ".yaml")
            }
        }
    }

    /// Tolerant read: a legitimate writer always emits all eight coordinate keys together, so a block
    /// missing (or mis-typed on) ANY key is damaged — it collapses to the fully-empty origin
    /// ("not linked") rather than a mixed partial that downstream would treat as linked. Never throws:
    /// a half-failed adopt must not brick the manifest, and a later write repairs it.
    static func parseInstalledOrigin(_ map: [String: Any]) -> InstalledOrigin {
        guard let repo = map["repo"] as? String,
              let path = map["path"] as? String,
              let ref = map["ref"] as? String,
              let installedCommit = map["installed_commit"] as? String,
              let installedTree = map["installed_tree"] as? String,
              let contentHash = map["content_hash"] as? String,
              let installedAt = parseDateValue(map["installed_at"]),
              let updatedAt = parseDateValue(map["updated_at"])
        else { return .empty }
        return InstalledOrigin(
            repo: repo,
            path: path,
            ref: ref,
            installedCommit: installedCommit,
            installedTree: installedTree,
            contentHash: contentHash,
            installedAt: installedAt,
            updatedAt: updatedAt
        )
    }

    private static func parseDateValue(_ value: Any?) -> Date? {
        (value as? String).flatMap(parseDate) ?? value as? Date
    }
}
