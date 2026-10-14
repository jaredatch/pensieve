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
        reportChanges: (Bool) -> Void = { _ in }
    ) -> Bool {
        guard !library.libraryUnavailable else {
            library.deletionNotice = .failed(
                "Pensieve couldn't read the skill library, so nothing was changed. Relaunch and try again.")
            return false
        }

        let cleanupResult = platformVM.removeAllDeploys(skill: skill, projects: projects, localProjectEvidence: {
            try platformVM.localSkillProjectDeployEvidence(skill: skill, projects: projects, context: context)
        })
        var retirementSaved = false
        var retiredRecords = false
        var deletionOutcome: SkillLibraryViewModel.SkillDeletionResult?
        let presentation = SkillLibraryViewModel.DeletionPresentation()
        defer {
            settleWaitingCleanup(cleanupResult, retirementSaved: retirementSaved,
                outcome: deletionOutcome, skill: skill, library: library, platformVM: platformVM)
            presentation.notice = library.deletionNotice
            let removedFiles: Bool
            switch deletionOutcome {
            case .deleted, .directoryDeletedRowRetained: removedFiles = true
            case .retainedDirectoryDeleteFailed, nil: removedFiles = false
            }
            reportChanges(cleanupResult.didChangeDeploys || (retirementSaved && retiredRecords) || removedFiles)
        }
        let cleanup = cleanupResult.batch
        if cleanup.hasFailures {
            library.deletionNotice = .failed(cleanupFailureMessage(cleanupResult, name: skill.name))
            return false
        }

        do {
            retiredRecords = try retire(skill: skill, context: context)
            try persist(context)
            retirementSaved = true
            library.regenerateManifest(.retireSkill(skill.directoryName), context: context)
        } catch {
            context.rollback()
            library.deletionNotice = .failed(
                "Couldn't retire deploy records for “\(skill.name)”: \(error.localizedDescription). "
                    + retainedSkillMessage(didChangeDeploys: cleanupResult.didChangeDeploys))
            return false
        }

        let outcome = library.deleteSkillEntry(skill, context: context, presentation: presentation, persist: persist)
        deletionOutcome = outcome
        let manifestNote = waitingCleanupNote(library: library, waitingProjects: cleanupResult.waitingProjects)
        return present(outcome, skill: skill, manifestNote: manifestNote, library: library)
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
                                             library: SkillLibraryViewModel, platformVM: PlatformViewModel) {
        if retirementSaved {
            if let error = platformVM.finishWaitingSkillCleanup(cleanup) {
                let message = library.deletionNotice?.message ?? ""
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
                switch library.deletionNotice {
                case .failed: library.deletionNotice = .failed(warning)
                case .pending: library.deletionNotice = .pending(warning)
                case .warning, nil: library.deletionNotice = .warning(warning)
                }
            }
        } else {
            do { try platformVM.abandonWaitingSkillCleanup(cleanup) } catch {
                let message = library.deletionNotice?.message ?? "The skill was kept."
                library.deletionNotice = .failed(message + " Couldn't withdraw this attempt's waiting cleanup: "
                    + error.localizedDescription)
            }
        }
    }

    private static func retainedSkillMessage(didChangeDeploys: Bool) -> String {
        didChangeDeploys
            ? "Agent links and rules already removed stay removed; the skill was kept so you can retry."
            : "The skill was kept so you can retry."
    }

    private static func retire(skill: Skill, context: ModelContext) throws -> Bool {
        var changed = false
        let intents = try context.fetch(FetchDescriptor<MachineDeployIntent>())
        for intent in intents where intent.skillSlug == skill.directoryName { context.delete(intent); changed = true }
        let ledger = try context.fetch(FetchDescriptor<IntentAssignment>())
        for row in ledger where row.skillID == skill.id { context.delete(row); changed = true }
        let categoryLedger = try context.fetch(FetchDescriptor<SkillProjectAssignment>())
        for row in categoryLedger where row.skillID == skill.id { context.delete(row); changed = true }
        for category in try context.fetch(FetchDescriptor<Category>())
            where category.skillSlugs.contains(skill.directoryName) {
            category.skillSlugs.removeAll { $0 == skill.directoryName }
            changed = true
        }
        return changed
    }

    private static func present(
        _ outcome: SkillLibraryViewModel.SkillDeletionResult,
        skill: Skill,
        manifestNote: String,
        library: SkillLibraryViewModel
    ) -> Bool {
        switch outcome {
        case .deleted:
            if manifestNote.isEmpty {
                library.deletionNotice = nil
            } else {
                library.deletionNotice = .warning("Deleted “\(skill.name)”." + manifestNote)
            }
            return true
        case .directoryDeletedRowRetained(let detail):
            library.deletionNotice = .pending(
                "Removed “\(skill.name)”'s files, but the library couldn't save the change. "
                    + "The entry stays listed but can't be edited; delete it again from the list, "
                    + "or relaunch Pensieve and the library rebuild drops it. (\(detail))" + manifestNote)
            return false
        case .retainedDirectoryDeleteFailed:
            library.deletionNotice = .failed((library.error ?? "Couldn't delete the skill.") + manifestNote)
            return false
        }
    }
}
