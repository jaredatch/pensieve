import Foundation
import SwiftData

enum SkillDeletionFlow {
    static func delete(
        skill: Skill,
        library: SkillLibraryViewModel,
        platformVM: PlatformViewModel,
        projects: [Project],
        context: ModelContext,
        persist: (ModelContext) throws -> Void = { try $0.save() },
        reportChanges: (Bool) -> Void = { _ in },
        presentation: SkillLibraryViewModel.DeletionPresentation = .init()
    ) -> Bool {
        defer { if presentation.presentsInWindow { library.deletionNotice = presentation.notice } }
        guard canDelete(skill, library: library, presentation: presentation) else { return false }

        let cleanupResult = platformVM.removeAllDeploys(skill: skill, projects: projects, localProjectEvidence: {
            try platformVM.localSkillProjectDeployEvidence(skill: skill, projects: projects, context: context)
        })
        var retirementSaved = false
        var retiredRecords = false
        var deletionOutcome: SkillLibraryViewModel.SkillDeletionResult?
        defer {
            settleWaitingCleanup(cleanupResult, retirementSaved: retirementSaved,
                outcome: deletionOutcome, skill: skill, presentation: presentation, platformVM: platformVM)
            let removedFiles: Bool
            switch deletionOutcome {
            case .deleted, .directoryDeletedRowRetained: removedFiles = true
            case .retainedDirectoryDeleteFailed, nil: removedFiles = false
            }
            reportChanges(cleanupResult.didChangeDeploys || (retirementSaved && retiredRecords) || removedFiles)
        }
        if cleanupResult.batch.hasFailures {
            presentation.notice = .failed(cleanupFailureMessage(cleanupResult, name: skill.name))
            return false
        }

        do {
            let retirement = try prepareRetirement(skill, library: library, platform: platformVM, context: context)
            retiredRecords = retirement.changed
            try persist(context)
            retirementSaved = true
            library.regenerateManifest(retirement.change, context: context,
                showsFailure: presentation.presentsInWindow) { failure in
                if !presentation.presentsInWindow, let failure {
                    let earlier = presentation.notice.map { $0.message + " " } ?? ""
                    presentation.notice = .failed(earlier + "Couldn't publish retired deploy records: "
                        + failure.localizedDescription)
                }
            }
        } catch {
            context.rollback()
            presentation.notice = .failed(
                "Couldn't retire deploy records for “\(skill.name)”: \(error.localizedDescription). "
                    + retainedSkillMessage(didChangeDeploys: cleanupResult.didChangeDeploys))
            return false
        }

        let deletedID = skill.id, deletedSlug = skill.directoryName, deletedCreation = skill.createdAt
        let outcome = library.deleteSkillEntry(skill, context: context, presentation: presentation, persist: persist)
        deletionOutcome = outcome
        recheckDeletion(outcome, id: deletedID, slug: deletedSlug, createdAt: deletedCreation, library: library, context: context)
        let manifestNote = waitingCleanupNote(library: library, waitingProjects: cleanupResult.waitingProjects)
        return present(outcome, skill: skill, manifestNote: manifestNote, presentation: presentation)
    }

    private static func recheckDeletion(_ outcome: SkillLibraryViewModel.SkillDeletionResult, id: UUID, slug: String,
                                        createdAt: Date, library: SkillLibraryViewModel, context: ModelContext) {
        switch outcome {
        case .deleted, .directoryDeletedRowRetained:
            library.manifestSaves?.recheckRemovedSkillDeletion(slug, createdAt: createdAt, context: context) { [weak library] in
                library?.liftReturnedSkillQuarantine(id: id, slug: slug)
            }
        case .retainedDirectoryDeleteFailed: break
        }
    }

    private static func canDelete(_ skill: Skill, library: SkillLibraryViewModel,
                                  presentation: SkillLibraryViewModel.DeletionPresentation) -> Bool {
        guard !library.libraryUnavailable else {
            presentation.notice = .failed(
                "Pensieve couldn't read the skill library, so nothing was changed. Relaunch and try again.")
            return false
        }
        guard library.manifestSaves?.items.contains(where: { item in
            guard case .createSkill(let overlay) = item.change else { return false }
            return overlay.slug == skill.directoryName
        }) != true else {
            presentation.notice = .failed("Pensieve is still saving this skill. Try deleting it again in a moment.")
            return false
        }
        return true
    }

    private static func prepareRetirement(_ skill: Skill, library: SkillLibraryViewModel,
                                          platform: PlatformViewModel, context: ModelContext) throws
        -> (changed: Bool, change: ManifestChange) {
        let localOnly = library.manifestSaves?.hasCollision(skill.directoryName, context: context) == true
        let machine = localOnly ? try MachineIdentity(fileService: library.fileService,
            appSupportDir: platform.deployStateStore.appSupportDir).identifier() : nil
        let changed = try retire(skill: skill, context: context, machine: machine)
        return (changed, machine.map { .retireLocalSkill(skill.directoryName, $0) } ?? .retireSkill(skill.directoryName))
    }

    private static func cleanupFailureMessage(_ result: SkillCleanupResult, name: String) -> String {
        let cleanup = result.batch
        var messages = cleanup.readFailures.map(\.message)
        if !cleanup.failures.isEmpty {
            let details = cleanup.failures
                .map { "\($0.platform.displayName): \($0.error ?? "unknown error")" }.joined(separator: "; ")
            messages.insert("Couldn't remove agent links and rules for “\(name)”: \(details).", at: 0)
        }
        messages.append(retainedSkillMessage(didChangeDeploys: result.didChangeDeploys))
        return messages.joined(separator: " ")
    }

    private static func waitingCleanupNote(
        library: SkillLibraryViewModel, waitingProjects: [String]
    ) -> String {
        var manifestNote = ""
        library.notifier()

        if !waitingProjects.isEmpty {
            manifestNote += " Links and rules in \(waitingProjects.joined(separator: ", ")) "
                + "will be removed when the folder is back and can be checked."
        }
        return manifestNote
    }

    private static func settleWaitingCleanup(_ cleanup: SkillCleanupResult, retirementSaved: Bool,
                                             outcome: SkillLibraryViewModel.SkillDeletionResult?, skill: Skill,
                                             presentation: SkillLibraryViewModel.DeletionPresentation,
                                             platformVM: PlatformViewModel) {
        if retirementSaved {
            if let error = platformVM.finishWaitingSkillCleanup(cleanup) {
                let message = presentation.notice?.message ?? ""
                let namedMessage: String
                switch outcome {
                case .deleted:
                    namedMessage = message.isEmpty ? "Deleted “\(skill.name)”." : message
                case .directoryDeletedRowRetained:
                    namedMessage = message.isEmpty ? "Removed “\(skill.name)”'s files; its entry stays listed." : message
                case .retainedDirectoryDeleteFailed, nil:
                    namedMessage = "The skill “\(skill.name)” was kept." + (message.isEmpty ? "" : " " + message)
                }
                let warning = namedMessage + " Waiting cleanup was saved, "
                    + "but its deployment records couldn't be retired: \(error)."
                switch presentation.notice {
                case .failed: presentation.notice = .failed(warning)
                case .pending: presentation.notice = .pending(warning)
                case .warning, nil: presentation.notice = .warning(warning)
                }
            }
        } else {
            do { try platformVM.abandonWaitingSkillCleanup(cleanup) } catch {
                let message = presentation.notice?.message ?? "The skill was kept."
                presentation.notice = .failed(message + " Couldn't withdraw this attempt's waiting cleanup: "
                    + error.localizedDescription)
            }
        }
    }

    private static func retainedSkillMessage(didChangeDeploys: Bool) -> String {
        didChangeDeploys
            ? "Agent links and rules already removed stay removed; the skill was kept so you can retry."
            : "The skill was kept so you can retry."
    }

    private static func retire(skill: Skill, context: ModelContext, machine: String?) throws -> Bool {
        var changed = false
        let intents = try context.fetch(FetchDescriptor<MachineDeployIntent>())
        for intent in intents where intent.skillSlug == skill.directoryName && (machine == nil || intent.machineID == machine) {
            context.delete(intent); changed = true
        }
        let ledger = try context.fetch(FetchDescriptor<IntentAssignment>())
        for row in ledger where row.skillID == skill.id { context.delete(row); changed = true }
        let categoryLedger = try context.fetch(FetchDescriptor<SkillProjectAssignment>())
        for row in categoryLedger where row.skillID == skill.id { context.delete(row); changed = true }
        for category in try context.fetch(FetchDescriptor<Category>())
            where machine == nil && category.skillSlugs.contains(skill.directoryName) {
            category.skillSlugs.removeAll { $0 == skill.directoryName }
            changed = true
        }
        return changed
    }

    private static func present(
        _ outcome: SkillLibraryViewModel.SkillDeletionResult,
        skill: Skill,
        manifestNote: String,
        presentation: SkillLibraryViewModel.DeletionPresentation
    ) -> Bool {
        switch outcome {
        case .deleted:
            if manifestNote.isEmpty {
                presentation.notice = nil
            } else {
                presentation.notice = .warning("Deleted “\(skill.name)”." + manifestNote)
            }
            return true
        case .directoryDeletedRowRetained(let detail):
            presentation.notice = .pending(
                "Removed “\(skill.name)”'s files, but the library couldn't save the change. "
                    + "The entry stays listed but can't be edited; delete it again from the list, "
                    + "or relaunch Pensieve and the library rebuild drops it. (\(detail))" + manifestNote)
            return false
        case .retainedDirectoryDeleteFailed(let detail):
            presentation.notice = .failed("Failed to delete skill: " + detail + manifestNote)
            return false
        }
    }
}
