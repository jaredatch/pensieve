import Foundation
import SwiftData

enum SkillDeletionFlow {
    static func delete(
        skill: Skill,
        library: SkillLibraryViewModel,
        platformVM: PlatformViewModel,
        projects: [Project],
        context: ModelContext,
        persist: (ModelContext) throws -> Void = { try $0.save() }
    ) -> Bool {
        guard !library.libraryUnavailable else {
            library.deletionNotice = .failed(
                "Pensieve couldn't read the skill library, so nothing was changed. Relaunch and try again.")
            return false
        }

        let locallyDeployedPaths: Set<String>
        do {
            locallyDeployedPaths = try localCursorDeployPaths(skill: skill, projects: projects,
                                                              platformVM: platformVM, context: context)
        } catch {
            library.deletionNotice = .failed("Couldn't read local deploy history for “\(skill.name)”: "
                + "\(error.localizedDescription). The skill was kept so you can retry.")
            return false
        }
        let cleanup = platformVM.removeAllDeploys(skill: skill, projects: projects, locallyDeployedPaths: locallyDeployedPaths)
        if cleanup.hasFailures {
            var messages = cleanup.readFailures.map(\.message)
            if !cleanup.failures.isEmpty {
                let details = cleanup.failures
                    .map { "\($0.platform.displayName): \($0.error ?? "unknown error")" }
                    .joined(separator: "; ")
                messages.insert(
                    "Couldn't finish cleaning up “\(skill.name)” on \(cleanup.failures.count) agent artifact(s) — "
                        + "\(details).",
                    at: 0
                )
            }
            messages.append("Agent links and rules already removed stay removed; the skill was kept so you can retry.")
            library.deletionNotice = .failed(messages.joined(separator: " "))
            return false
        }

        do {
            try retire(skill: skill, context: context)
            try persist(context)
        } catch {
            context.rollback()
            library.deletionNotice = .failed(
                "Removed agent links and rules for “\(skill.name)”, but couldn't retire its deploy records: "
                    + "\(error.localizedDescription). The skill was kept so you can retry.")
            return false
        }

        let outcome = library.deleteSkillEntry(skill, context: context, persist: persist)
        var manifestNote = ""
        do {
            try library.writeManifest(context: context)
            library.notifier()
        } catch {
            manifestNote = " The sync manifest couldn't be updated and will regenerate on the next change."
        }

        return present(outcome, skill: skill, manifestNote: manifestNote, library: library)
    }

    private static func localCursorDeployPaths(
        skill: Skill, projects: [Project], platformVM: PlatformViewModel, context: ModelContext
    ) throws -> Set<String> {
        let paths = Array(platformVM.projectCursorPathsNeedingHistory(skill: skill, projects: projects))
        guard !paths.isEmpty else { return [] }
        let skillID = skill.id
        let predicate = #Predicate<DeployRecord> {
            $0.skillID == skillID && $0.projectID != nil && paths.contains($0.targetPath)
        }
        // SwiftData cannot compare captured Codable enums; the predicate bounds Cursor paths first.
        return Set(try context.fetch(FetchDescriptor(predicate: predicate))
            .filter { $0.platform == .cursor }.map(\.targetPath))
    }

    private static func retire(skill: Skill, context: ModelContext) throws {
        let intents = try context.fetch(FetchDescriptor<MachineDeployIntent>())
        for intent in intents where intent.skillSlug == skill.directoryName { context.delete(intent) }
        let ledger = try context.fetch(FetchDescriptor<IntentAssignment>())
        for row in ledger where row.skillID == skill.id { context.delete(row) }
        let categoryLedger = try context.fetch(FetchDescriptor<SkillProjectAssignment>())
        for row in categoryLedger where row.skillID == skill.id { context.delete(row) }
        let scenarioLedger = try context.fetch(FetchDescriptor<ScenarioAssignment>())
        for row in scenarioLedger where row.skillID == skill.id { context.delete(row) }
        for category in try context.fetch(FetchDescriptor<Category>())
            where category.skillSlugs.contains(skill.directoryName) {
            category.skillSlugs.removeAll { $0 == skill.directoryName }
        }
    }

    private static func present(
        _ outcome: SkillLibraryViewModel.SkillDeletionResult,
        skill: Skill,
        manifestNote: String,
        library: SkillLibraryViewModel
    ) -> Bool {
        switch outcome {
        case .deleted, .deletedManifestStale:
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
