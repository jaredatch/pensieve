import Foundation

/// Resolves entity → skills for the detail column's "Skills" sections. Every function is a pure
/// filter over already-fetched models: NO file IO, NO SwiftData fetches, nothing that can block a
/// body evaluation. The project case is deliberately absent — it needs disk and lives in
/// ProjectSkillsSnapshot (PLAN-27 / 27.5).
enum RelatedSkills {
    static func forCategory(_ category: Category, in skills: [Skill]) -> [Skill] {
        let slugs = Set(category.skillSlugs)
        return skills.filter { slugs.contains($0.directoryName) }
    }

    static func forScenario(_ scenario: Scenario, in skills: [Skill]) -> [Skill] {
        let slugs = Set(scenario.skillSlugs)
        return skills.filter { slugs.contains($0.directoryName) }
    }

    static func forTag(_ tag: String, in skills: [Skill]) -> [Skill] {
        skills.filter { $0.tags.contains(tag) }
    }

    /// A machine's deploy rows carry slugs reported by ANOTHER Mac. That machine may have skills
    /// this one does not, so resolution is optional by design: an unresolvable slug is shown as
    /// plain, non-navigable text rather than hidden (the user should still see what that machine
    /// has) and rather than made clickable (there is nothing local to open).
    static func resolve(slug: String, in skills: [Skill]) -> Skill? {
        skills.first { $0.directoryName == slug }
    }
}

extension Array where Element == Skill {
    /// The one total ordering every related-skills list renders in: localized-standard name order
    /// (Finder's, matching `@Query(sort: \Skill.name)`) with the unique directory name as
    /// tie-breaker, so equal names cannot render nondeterministically across surfaces.
    func relatedSkillsOrdered() -> [Skill] {
        sorted(using: [KeyPathComparator(\Skill.name, comparator: .localizedStandard),
                       KeyPathComparator(\Skill.directoryName)])
    }
}
