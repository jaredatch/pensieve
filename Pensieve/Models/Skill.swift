import Foundation
import SwiftData

@Model
final class Skill {
    @Attribute(.unique) var id: UUID
    var name: String
    var skillDescription: String
    var tags: [String]
    var scope: SkillScope
    var directoryName: String

    /// Cursor-specific config, stored as JSON Data.
    /// Only Cursor needs adapter config — Claude Code and Codex just get symlinks.
    var cursorConfigData: Data?

    var createdAt: Date
    var updatedAt: Date
    var importedFrom: String?
    /// Rebuildable cache of the manifest's installed-origin fact. Optional for lightweight migration.
    var installedOriginData: Data?

    // Volatile, per-machine update-check state. These fields never enter the manifest.
    var updateAvailable: Bool = false
    var lastCheckedAt: Date?
    var lastCheckedHead: String?
    var upstreamTree: String?
    var upstreamCommit: String?
    var upstreamCommitDate: Date?
    var checkError: String?

    init(
        name: String,
        skillDescription: String = "",
        tags: [String] = [],
        scope: SkillScope = .user,
        directoryName: String,
        cursorConfig: CursorAdapterConfig? = nil,
        importedFrom: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.skillDescription = skillDescription
        self.tags = tags
        self.scope = scope
        self.directoryName = directoryName
        self.cursorConfigData = cursorConfig.flatMap { try? JSONEncoder().encode($0) }
        self.createdAt = Date()
        self.updatedAt = Date()
        self.importedFrom = importedFrom
        self.installedOriginData = nil
        self.updateAvailable = false
        self.lastCheckedAt = nil
        self.lastCheckedHead = nil
        self.upstreamTree = nil
        self.upstreamCommit = nil
        self.upstreamCommitDate = nil
        self.checkError = nil
    }

    // MARK: - Computed

    func canonicalPath(skillsDirectory: String) -> String {
        skillsDirectory + "/" + directoryName + "/SKILL.md"
    }

    func canonicalDir(skillsDirectory: String) -> String {
        skillsDirectory + "/" + directoryName
    }

    var cursorConfig: CursorAdapterConfig? {
        get {
            guard let data = cursorConfigData else { return nil }
            return try? JSONDecoder().decode(CursorAdapterConfig.self, from: data)
        }
        set {
            cursorConfigData = newValue.flatMap { try? JSONEncoder().encode($0) }
            updatedAt = Date()
        }
    }

    var installedOrigin: InstalledOrigin? {
        get {
            guard let data = installedOriginData else { return nil }
            return try? JSONDecoder().decode(InstalledOrigin.self, from: data)
        }
        set {
            installedOriginData = newValue.flatMap { try? JSONEncoder().encode($0) }
        }
    }

    /// True only when the skill is linked to an upstream repo with real coordinates.
    /// A tolerant-read `.empty` installed origin (a v2 tree or a damaged v3 block, per PLAN-19 / 19.1)
    /// is deliberately NOT linked — it must render as "not linked" everywhere in the provenance surface.
    var hasLinkedOrigin: Bool {
        guard let origin = installedOrigin else { return false }
        return origin != .empty
    }

    func resetUpdateCheckState() {
        updateAvailable = false
        lastCheckedAt = nil
        lastCheckedHead = nil
        upstreamTree = nil
        upstreamCommit = nil
        upstreamCommitDate = nil
        checkError = nil
    }

}
