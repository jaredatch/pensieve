import Foundation
import SwiftData

/// A local rename holds sync.lock only through folder, row and artifact changes. Manifest publication
/// is queued after release because its worker opens the same lock on another descriptor.
@MainActor
enum SkillRenameFlow {
    static func rename(
        skill: Skill, to name: String, library: SkillLibraryViewModel, platformVM: PlatformViewModel,
        projects: [Project], context: ModelContext, persist: (ModelContext) throws -> Void = { try $0.save() }
    ) -> Bool {
        guard !library.addsFenced, !library.isWriteFenced(skill) else {
            library.error = library.addFenceReason ?? "This skill's file can't be read. Relaunch and try again."
            return false
        }
        guard !library.hasUnsavedChanges(for: skill) else {
            library.error = "Save or discard the skill's unsaved changes before renaming it."
            return false
        }
        let operation = Operation(skill: skill, name: name, library: library, platform: platformVM,
                                  projects: projects, context: context)
        do {
            let document = try operation.prepareDocument()
            guard let lock = try operation.acquireLock() else { return false }
            let succeeded: Bool
            do {
                defer { lock.release() }
                succeeded = operation.perform(document: document, persist: persist)
            }
            if succeeded {
                if operation.oldSlug != operation.newSlug {
                    library.regenerateManifest(.renameSkill(operation.oldSlug, operation.newSlug), context: context)
                }
                library.notifier()
            }
            return succeeded
        } catch {
            library.error = "Couldn't rename skill: \(error.localizedDescription)"
            return false
        }
    }

    private final class Operation {
        let skill: Skill
        let name: String
        let library: SkillLibraryViewModel
        let platform: PlatformViewModel
        let projects: [Project]
        let context: ModelContext
        let oldSlug: String
        let newSlug: String
        var original = ""
        var oldName = ""
        var oldUpdatedAt = Date()
        var memberships: [(Category, [String])] = []
        var moved = false
        var wroteDocument = false
        var cleanup = SkillCleanupResult()
        var planned: [DeployRemovalKey] = []

        init(skill: Skill, name: String, library: SkillLibraryViewModel, platform: PlatformViewModel,
             projects: [Project], context: ModelContext) {
            self.skill = skill; self.name = name; self.library = library; self.platform = platform
            self.projects = projects; self.context = context
            oldSlug = skill.directoryName; newSlug = SkillStore.slugify(name)
        }

        func prepareDocument() throws -> String {
            if let problem = SkillLibraryViewModel.renameNameProblem(name) { throw RenameError(problem) }
            let rows = try context.fetch(FetchDescriptor<Skill>())
            if let taken = rows.first(where: { $0.id != skill.id && $0.directoryName.lowercased() == newSlug }) {
                throw RenameError("The folder \(taken.directoryName) is taken.")
            }
            guard let source = String(validating: try library.skillStore.readData(directoryName: oldSlug), as: UTF8.self) else {
                throw RenameError("The skill's file can't be read as UTF-8.")
            }
            original = source
            oldName = skill.name
            oldUpdatedAt = skill.updatedAt
            memberships = try context.fetch(FetchDescriptor<Category>()).map { ($0, $0.skillSlugs) }
            // normalizeIdentity validates with the ordinary parser, whose input has no BOM.
            // Keep the editor document's marker outside that splice and restore it afterwards.
            let hasBOM = original.unicodeScalars.first == "\u{feff}"
            let input = hasBOM ? String(original.unicodeScalars.dropFirst()) : original
            let parsed = SkillParser.parse(input)
            guard let description = parsed.description,
                  let normalized = SkillSerializer.normalizeIdentity(name: name, description: description, parsed: parsed) else {
                throw RenameError("The frontmatter can't be rewritten safely.")
            }
            let document = (hasBOM ? "\u{feff}" : "") + normalized
            do {
                try SkillDocumentEditing.validateFrontmatter(SkillParser.parse(document, retainingBOM: true), currentName: name)
            } catch { throw RenameError("The frontmatter can't be rewritten safely: \(error.localizedDescription)") }
            return document
        }

        func acquireLock() throws -> SyncLock? {
            let path = library.manifestSaves?.lockPath ?? platform.deployStateStore.appSupportDir + "/sync.lock"
            do {
                guard let lock = try SyncLock.tryAcquireReportingErrors(at: path) else {
                    library.error = "Pensieve is busy syncing or finishing another task. Try renaming again in a moment."
                    return nil
                }
                return lock
            } catch {
                throw RenameError("Pensieve couldn't open its lock file, so nothing was renamed. "
                    + "Make sure sync.lock in Pensieve's Application Support folder is a file you can write to, then try again.")
            }
        }

        func perform(document: String, persist: (ModelContext) throws -> Void) -> Bool {
            library.error = nil
            if oldSlug != newSlug, !removeDeployments() { return false }
            do {
                if oldSlug != newSlug {
                    try library.skillStore.renameSkill(directoryName: oldSlug, to: newSlug)
                    moved = true
                }
                try library.skillStore.writeBody(directoryName: newSlug, body: document)
                wroteDocument = true
                try updateRows()
                try persist(context)
            } catch { return recover(from: error) }
            library.acceptRename(from: oldSlug, to: newSlug, document: document)
            if oldSlug != newSlug { restoreDeployments(under: newSlug, reconcile: true) }
            var notices: [String] = library.error.map { [$0] } ?? []
            if let failure = platform.finishWaitingSkillCleanup(cleanup) {
                notices.append("Renamed the skill, but couldn't retire waiting deployment records: \(failure).")
            }
            if !cleanup.waitingProjects.isEmpty {
                notices.append("Links and rules in \(cleanup.waitingProjects.joined(separator: ", ")) "
                    + "will be removed when the folder is back and can be checked.")
            }
            library.error = notices.isEmpty ? nil : notices.joined(separator: " ")
            return true
        }

        private func removeDeployments() -> Bool {
            let evidence = { try self.platform.localSkillProjectDeployEvidence(
                skill: self.skill, projects: self.projects, context: self.context) }
            let preview = platform.removeAllDeploys(skill: skill, projects: projects, dryRun: true,
                localProjectEvidence: evidence)
            planned = preview.plannedRemovals
            if preview.batch.hasFailures {
                library.error = failureMessage(preview.batch) + " The skill was kept so you can retry."
                return false
            }
            cleanup = platform.removeAllDeploys(skill: skill, projects: projects, localProjectEvidence: evidence)
            guard !cleanup.batch.hasFailures else {
                library.error = failureMessage(cleanup.batch)
                    + " Agent links and rules already removed stay removed; the skill was kept so you can retry."
                // Retain the deletion flow's partial-removal notice; restore every pair that can be restored.
                restoreDeployments(under: oldSlug, reconcile: false)
                abandonWaitingCleanup()
                return false
            }
            return true
        }

        private func updateRows() throws {
            skill.name = name
            skill.updatedAt = Date()
            guard oldSlug != newSlug else { return }
            skill.directoryName = newSlug
            for intent in try context.fetch(FetchDescriptor<MachineDeployIntent>()) where intent.skillSlug == oldSlug {
                context.insert(MachineDeployIntent(machineID: intent.machineID, skillSlug: newSlug,
                    platformRaw: intent.platformRaw, projectKey: intent.projectKey))
                context.delete(intent)
            }
            for row in try context.fetch(FetchDescriptor<IntentAssignment>())
                where row.skillID == skill.id { context.delete(row) }
            for row in try context.fetch(FetchDescriptor<SkillProjectAssignment>())
                where row.skillID == skill.id { context.delete(row) }
            let removed = Set(planned.map(\.artifactPath))
            for row in try context.fetch(FetchDescriptor<DeployRecord>())
                where row.skillID == skill.id && removed.contains(row.targetPath) { context.delete(row) }
            for category in try context.fetch(FetchDescriptor<Category>()) {
                category.skillSlugs = category.skillSlugs.map { $0 == oldSlug ? newSlug : $0 }
            }
        }

        private func recover(from error: Error) -> Bool {
            context.rollback()
            // SwiftData rollback restores stored rows but can leave registered array/scalar values stale.
            skill.directoryName = oldSlug
            skill.name = oldName
            skill.updatedAt = oldUpdatedAt
            for (category, slugs) in memberships { category.skillSlugs = slugs }
            context.processPendingChanges()
            do {
                if moved {
                    try library.skillStore.renameSkill(directoryName: newSlug, to: oldSlug)
                    moved = false
                }
                if wroteDocument { try library.skillStore.writeBody(directoryName: oldSlug, body: original) }
            } catch {
                library.error = "Couldn't restore the skill: \(error.localizedDescription). The folder is now \(newSlug) "
                    + "on disk while the library still lists \(oldSlug). A relaunch's rebuild lists it as a new skill."
                return false
            }
            let failure = error as NSError
            let reason = failure.domain == NSPOSIXErrorDomain && failure.code == Int(POSIXErrorCode.EEXIST.rawValue)
                ? "The folder \(newSlug) is taken." : error.localizedDescription
            library.error = "Couldn't rename skill: \(reason)"
            restoreDeployments(under: oldSlug, reconcile: false)
            abandonWaitingCleanup()
            library.acceptRename(from: newSlug, to: oldSlug, document: original)
            library.error = (library.error ?? "") + " The skill was kept so you can retry."
            return false
        }

        private func restoreDeployments(under slug: String, reconcile: Bool) {
            guard skill.directoryName == slug else { return }
            let deferred = Set(cleanup.deferredRemovals.map(\.key))
            var batch = BatchResult()
            for pair in planned where !deferred.contains(pair) {
                let target: DeployTarget
                if let path = pair.projectPath {
                    guard let project = projects.first(where: { $0.path == path }) else { continue }
                    target = .project(project)
                } else { target = .userWide }
                batch.append(platform.deployBatch(skills: [skill], platforms: [pair.platform], target: target, context: context))
            }
            if reconcile {
                let identity = MachineIdentity(fileService: library.fileService,
                    appSupportDir: platform.deployStateStore.appSupportDir)
                batch.append(IntentReconciler(platformVM: platform, machineIdentity: identity)
                    .reconcileDeployments(context: context))
                batch.append(CategoryReconciler(platformVM: platform).reconcileDeployments(context: context))
            }
            // An unavailable project is expected and already carries the waiting-cleanup notice.
            if batch.failures.contains(where: { $0.projectFolderError == nil }) || !batch.readFailures.isEmpty {
                library.error = (library.error.map { $0 + " " } ?? "") + "Some agent deployments couldn't be restored. "
                    + failureMessage(batch)
            }
        }

        private func abandonWaitingCleanup() {
            do { try platform.abandonWaitingSkillCleanup(cleanup) } catch {
                library.error = (library.error ?? "")
                    + " Couldn't withdraw this attempt's waiting cleanup: \(error.localizedDescription)."
            }
        }

        private func failureMessage(_ batch: BatchResult) -> String {
            (batch.readFailures.map(\.message) + batch.failures.compactMap(\.error)).joined(separator: " ")
        }
    }

    private struct RenameError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
