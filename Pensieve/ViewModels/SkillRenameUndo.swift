import Foundation
import SwiftData

/// The local inverse survives the short-lived rename operation until its queued save settles.
@MainActor
final class SkillRenameUndo {
    let skill: Skill
    let oldName: String
    let oldSlug: String
    let newSlug: String
    let library: SkillLibraryViewModel
    let platform: PlatformViewModel
    let projects: [Project]
    let planned: [DeployRemovalKey]
    let cleanup: SkillCleanupResult
    let assignments: ManifestSnapshot

    init(skill: Skill, oldName: String, oldSlug: String, newSlug: String, library: SkillLibraryViewModel,
         platform: PlatformViewModel, projects: [Project], planned: [DeployRemovalKey], cleanup: SkillCleanupResult,
         assignments: ManifestSnapshot) {
        self.skill = skill; self.oldName = oldName; self.oldSlug = oldSlug; self.newSlug = newSlug
        self.library = library; self.platform = platform; self.projects = projects
        self.planned = planned; self.cleanup = cleanup; self.assignments = assignments
    }

    func restore(durable: ManifestSnapshot, following: [ManifestChange], context: ModelContext) throws -> String? {
        guard try !library.skillStore.slugEntryExists(oldSlug),
              try !context.fetch(FetchDescriptor<Skill>()).contains(where: {
                  $0.id != skill.id && $0.directoryName.lowercased() == oldSlug.lowercased()
              }) else { throw RestoreError("the old name “\(oldSlug)” is taken.") }
        guard let current = String(validating: try library.skillStore.readData(directoryName: newSlug), as: UTF8.self) else {
            throw RestoreError("the skill's file can't be read as UTF-8.")
        }
        let restored = try Self.restoringName(in: current, to: oldName)
        let before = try ManifestService().snapshot(from: context)
        let window = restoredAssignments(before, durable: durable, following: following)
        try library.skillStore.renameSkill(directoryName: newSlug, to: oldSlug)
        do {
            try library.skillStore.writeBody(directoryName: oldSlug, body: restored)
            skill.name = oldName
            skill.directoryName = oldSlug
            try acceptAssignments(window, context: context)
            try context.save()
        } catch {
            // Nothing half-moved is exposed when the save releases sync.lock.
            skill.name = SkillParser.parse(current, retainingBOM: true).name ?? skill.name
            skill.directoryName = newSlug
            try? acceptAssignments(before, context: context)
            try? context.save()
            try library.skillStore.renameSkill(directoryName: oldSlug, to: newSlug)
            try library.skillStore.writeBody(directoryName: newSlug, body: current)
            throw error
        }
        library.acceptRename(from: newSlug, to: oldSlug, document: restored, carryingDraft: true)
        return restoreDeployments(context: context)
    }

    private func restoredAssignments(_ before: ManifestSnapshot, durable: ManifestSnapshot,
                                     following: [ManifestChange]) -> ManifestSnapshot {
        var window = before
        window.deployIntents.removeAll { $0.skillSlug == newSlug }
        window.deployIntents += assignments.deployIntents.filter { $0.skillSlug == oldSlug }
        for index in window.categories.indices {
            window.categories[index].skillSlugs.removeAll { $0 == newSlug }
            if assignments.categories.contains(where: {
                $0.name == window.categories[index].name && $0.skillSlugs.contains(oldSlug)
            }), !window.categories[index].skillSlugs.contains(oldSlug) {
                window.categories[index].skillSlugs.append(oldSlug)
            }
        }
        // The target's folderless assignments are synced data, never this Mac's renamed skill.
        window.deployIntents += durable.deployIntents.filter { $0.skillSlug == newSlug }
        for record in durable.categories where record.skillSlugs.contains(newSlug) {
            if let index = window.categories.firstIndex(where: { $0.name == record.name }) {
                window.categories[index].skillSlugs.append(newSlug)
            } else { window.categories.append(record) }
        }
        for change in following { change.apply(to: &window) }
        return window
    }

    nonisolated static func restoringName(in document: String, to name: String) throws -> String {
        let hasBOM = document.unicodeScalars.first == "\u{feff}"
        let input = hasBOM ? String(document.unicodeScalars.dropFirst()) : document
        let parsed = SkillParser.parse(input)
        guard let description = parsed.description,
              let rewritten = SkillSerializer.normalizeIdentity(name: name, description: description, parsed: parsed) else {
            throw RestoreError("the frontmatter can't be rewritten safely.")
        }
        return (hasBOM ? "\u{feff}" : "") + rewritten
    }

    private func acceptAssignments(_ snapshot: ManifestSnapshot, context: ModelContext) throws {
        let rebuild = StoreRebuildService(fileService: library.fileService)
        var result = RebuildResult()
        _ = rebuild.rebuildCategories(snapshot: snapshot, context: context, result: &result)
        rebuild.rebuildDeployIntents(snapshot: snapshot, context: context, result: &result)
        if result.categoryReadFailed || result.deployIntentReadFailed { throw StoreIngestFailure(result) }
    }

    private func restoreDeployments(context: ModelContext) -> String? {
        // Remove artifacts while the row still supplies the new slug to the existing deploy sinks.
        skill.directoryName = newSlug
        let evidence = { try self.platform.localSkillProjectDeployEvidence(
            skill: self.skill, projects: self.projects, context: context) }
        let preview = platform.removeAllDeploys(skill: skill, projects: projects, dryRun: true, localProjectEvidence: evidence)
        let removed = platform.removeAllDeploys(skill: skill, projects: projects, localProjectEvidence: evidence)
        skill.directoryName = oldSlug
        var batch = removed.batch
        do {
            for row in try context.fetch(FetchDescriptor<IntentAssignment>()) where row.skillID == skill.id {
                context.delete(row)
            }
            for row in try context.fetch(FetchDescriptor<SkillProjectAssignment>()) where row.skillID == skill.id {
                context.delete(row)
            }
            let paths = Set(preview.plannedRemovals.map(\.artifactPath))
            for row in try context.fetch(FetchDescriptor<DeployRecord>())
                where row.skillID == skill.id && paths.contains(row.targetPath) { context.delete(row) }
            try context.save()
        } catch { batch.recordReadFailure("restoring skill deployments", error: error) }
        let deferred = Set(cleanup.deferredRemovals.map(\.key))
        for pair in planned where !deferred.contains(pair) {
            let target: DeployTarget
            if let path = pair.projectPath {
                guard let project = projects.first(where: { $0.path == path }) else { continue }
                target = .project(project)
            } else { target = .userWide }
            batch.append(platform.deployBatch(skills: [skill], platforms: [pair.platform], target: target, context: context))
        }
        let identity = MachineIdentity(fileService: library.fileService, appSupportDir: platform.deployStateStore.appSupportDir)
        batch.append(IntentReconciler(platformVM: platform, machineIdentity: identity).reconcileDeployments(context: context))
        batch.append(CategoryReconciler(platformVM: platform).reconcileDeployments(context: context))
        var notices: [String] = []
        if batch.failures.contains(where: { $0.projectFolderError == nil }) || !batch.readFailures.isEmpty {
            notices.append("Some agent deployments couldn't be restored. "
                + (batch.readFailures.map(\.message) + batch.failures.compactMap(\.error)).joined(separator: " "))
        }
        do { try platform.abandonWaitingSkillCleanup(cleanup) } catch {
            notices.append("Couldn't withdraw this attempt's waiting cleanup: \(error.localizedDescription).")
        }
        return notices.isEmpty ? nil : notices.joined(separator: " ")
    }
}

private struct RestoreError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
