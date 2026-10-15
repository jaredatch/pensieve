import Foundation
import SwiftData

struct SkillInstallPlan {
    struct Entry {
        let candidate: SkillCandidate
        let slug: String
        let action: String
    }
    let source: SkillFetchResult
    let entries: [Entry]
}

extension SkillInstallService {
    /// Read-only discovery and collision planning. Installation rechecks the same collision rule under its lock.
    func plan(url: String, skills: [String], rename: Bool, skip: Bool, context: ModelContext) throws -> SkillInstallPlan {
        let parsed = try SkillInstallURL.parseResult(url).get()
        let source: SkillFetchResult
        if parsed.form == .repo {
            source = try fetch(repo: parsed.repo, ref: parsed.ref, credential: nil)
        } else {
            source = try fetch(repo: parsed.repo, ref: parsed.ref, path: parsed.path ?? "", credential: nil)
        }
        let selected = source.candidates.filter { skills.isEmpty || skills.contains($0.slug) }
        guard Set(skills).isSubset(of: Set(source.candidates.map(\.slug))) else {
            throw SkillInstallError.unavailableCandidate(
                "A selected skill was not found. Preview the repository without --skill.")
        }
        let existing = try context.fetch(FetchDescriptor<Skill>())
        var reserved: Set<String> = []
        var entries: [SkillInstallPlan.Entry] = []
        for candidate in selected {
            try requireInstallable(candidate)
            if let installed = existing.first(where: {
                $0.installedOrigin?.repo == source.repo && $0.installedOrigin?.path == candidate.path
            }) {
                entries.append(.init(candidate: candidate, slug: installed.directoryName, action: "unchanged"))
                continue
            }
            var slug = candidate.slug
            var action = "install"
            if try collision(for: slug, context: context) != nil || reserved.contains(slug.lowercased()) {
                action = skip ? "skipped" : "collision"
                if rename {
                    var suffix = 2
                    repeat {
                        slug = candidate.slug + "-" + String(suffix)
                        suffix += 1
                    } while try collision(for: slug, context: context) != nil || reserved.contains(slug.lowercased())
                    action = "install"
                }
            }
            if action == "install" { reserved.insert(slug.lowercased()) }
            entries.append(.init(candidate: candidate, slug: slug, action: action))
        }
        return SkillInstallPlan(source: source, entries: entries)
    }
}
