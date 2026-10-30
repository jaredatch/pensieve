import Foundation
import SwiftData

extension SkillLibraryViewModel {
    /// Sheet admission includes row reservations and every disk entry, without following links.
    func renameValidationMessage(_ name: String, skill: Skill, context: ModelContext) -> String? {
        if let problem = Self.renameNameProblem(name) { return problem }
        let slug = SkillStore.slugify(name)
        do {
            if let taken = try context.fetch(FetchDescriptor<Skill>()).first(where: {
                $0.id != skill.id && $0.directoryName.lowercased() == slug.lowercased()
            }) { return "The folder \(taken.directoryName) is taken. Choose another name." }
            if slug == skill.directoryName { return nil }
            if try skillStore.slugEntryExists(slug) {
                let spelling = try fileService.listDirectory(at: skillsDirectory)
                    .first { $0.lowercased() == slug.lowercased() } ?? slug
                return "The folder \(spelling) is taken. Choose another name."
            }
            return nil
        } catch { return "Couldn't check the skill folders: \(error.localizedDescription)" }
    }

    static func renameNameProblem(_ name: String) -> String? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Enter a skill name." }
        guard name.lowercased().utf8.contains(where: { (97...122).contains($0) || (48...57).contains($0) }) else {
            return "The folder name needs a letter or digit."
        }
        guard SkillStore.slugify(name).utf8.count <= 64 else {
            return "The folder name is limited to 64 bytes, which the deploy records require."
        }
        return nil
    }

    /// Record both sides of a folder move as app writes before any queued watcher callback runs.
    func acceptRename(from old: String, to new: String, document: String) {
        withFingerprintLock {
            if old != new {
                lastWrittenBody[old] = ""
                pendingAppWrittenBody[old] = nil
                registeredAppWriteSlugs.remove(old)
            }
            lastWrittenBody[new] = document
            pendingAppWrittenBody[new] = nil
            registeredAppWriteSlugs.remove(new)
        }
        for slug in Set([old, new]) {
            coordinatorBaselineBodies[slug] = nil
            coordinatorObservedSlugs.remove(slug)
            coordinatorChangeSequences[slug] = nil
            folderChangeRevisions[slug] = nil
            externallyModified.remove(slug)
            textEditRevisions[slug] = nil
            externalChangeQuestions[slug] = nil
            drafts[slug] = nil
        }
        publishAppWriteRevision()
    }
}
