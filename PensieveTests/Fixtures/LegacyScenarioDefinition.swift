import CryptoKit
import Foundation
@testable import Pensieve

/// Writes old-build fixtures only. Current manifest writers carry their bytes without parsing them.
struct LegacyScenarioDefinition {
    var id: String
    var name: String
    var skillSlugs: [String]
    var agents: [String]

    static func fileName(name: String, id: String) -> String {
        let slug = name.lowercased().replacing(/[^a-z0-9\s-]/, with: "")
            .replacing(/\s+/, with: "-").replacing(/^-+|-+$/, with: "")
        let hash = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        return (slug.isEmpty ? "scn" : slug) + "-" + hash + ".yaml"
    }

    static func serialize(_ record: Self) -> String {
        var lines = ["id: " + SkillSerializer.quotedScalar(record.id),
                     "name: " + SkillSerializer.quotedScalar(record.name)]
        ManifestService.appendBlockList(&lines, key: "skill_slugs", values: record.skillSlugs)
        ManifestService.appendBlockList(&lines, key: "agents", values: record.agents)
        return lines.joined(separator: "\n") + "\n"
    }
}
