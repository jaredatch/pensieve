import Foundation

/// App-only `Skill`-typed convenience over the value-typed `SkillSerializer.serialize` (PLAN-12 / 12.1).
/// Kept out of the daemon target because it references the `@Model` `Skill` type.
extension SkillSerializer {
    static func serialize(skill: Skill, body: String) -> String {
        serialize(name: skill.name, description: skill.skillDescription, body: body)
    }
}
