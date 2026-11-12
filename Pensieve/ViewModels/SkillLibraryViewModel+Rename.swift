import Foundation
import SwiftData

extension SkillLibraryViewModel {
    /// Publish the current values as a create, retaining each previous name's move scope.
    func publishRenamedCreate(_ skill: Skill, from oldSlug: String, machineID: String?, context: ModelContext) {
        let origin: SkillOrigin
        if skill.installedOriginData != nil { origin = .installed(skill.installedOrigin ?? .empty) } else {
            origin = skill.importedFrom.map { .imported(from: $0) } ?? .authored
        }
        let current = SkillOverlay(slug: skill.directoryName, createdAt: skill.createdAt,
            scope: skill.scope, tags: skill.tags, cursor: skill.cursorConfig, agents: [], origin: origin)
        let previous = manifestSaves?.refused.first { $0.context === context && $0.createdSkill?.slug == oldSlug }
        let oldSlugs = (previous?.intentMove?.oldSlugs ?? []).union([oldSlug])
        let carriedSlugs = (previous?.intentMove?.carriedSlugs ?? [])
            .union(previous?.isCollisionHeld == true ? [] : [oldSlug])
        manifestSaves?.discardRefusedCreate(oldSlug, context: context)
        regenerateManifest(.createSkill(current), context: context, intentMove: machineID.map {
            ManifestLocalIntentMove(oldSlugs: oldSlugs, newSlug: skill.directoryName, machineID: $0, carriedSlugs: carriedSlugs)
        })
    }

    /// Sheet admission includes row reservations and every disk entry, without following links.
    func renameValidationMessage(_ name: String, skill: Skill, context: ModelContext) -> String? {
        if let problem = Self.renameNameProblem(name) { return problem }
        let slug = SkillStore.slugify(name)
        do {
            if let taken = try context.fetch(FetchDescriptor<Skill>()).first(where: {
                $0.id != skill.id && $0.directoryName.lowercased() == slug.lowercased()
            }) { return "The folder \(taken.directoryName) is taken. Choose another name." }
            if slug == skill.directoryName.lowercased() { return nil }
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
    func acceptRename(from old: String, to new: String, document: String, carryingDraft: Bool = false) {
        let carried = carryingDraft ? drafts[old] : nil
        let question = carryingDraft ? externalChangeQuestions[old] : nil
        let prompt = carryingDraft ? pendingUnsavedChanges : nil
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
        if var draft = carried {
            draft.body = (try? SkillRenameUndo.restoringName(in: draft.body, to: draft.skill.name)) ?? draft.body
            draft.baseline = draft.baseline.flatMap { try? SkillRenameUndo.restoringName(in: $0, to: draft.skill.name) }
            drafts[new] = draft
        }
        if let question { externalChangeQuestions[new] = question }
        if let prompt, prompt.directoryName == old {
            pendingUnsavedChanges = UnsavedChangesPrompt(id: prompt.id, directoryName: new,
                fileName: "\(new)/SKILL.md", reason: prompt.reason)
        }
        publishAppWriteRevision()
    }
}
