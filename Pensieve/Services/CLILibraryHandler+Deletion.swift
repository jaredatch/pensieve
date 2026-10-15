import Foundation
import SwiftData

extension CLILibraryHandler {
    private func deletionFailed(_ notice: SkillLibraryViewModel.DeletionNotice?) -> Bool {
        if case .failed = notice { return true }
        if case .pending = notice { return true }
        return false
    }

    func delete(_ slug: String, options: CLILibraryOptions) async throws -> CLIReply {
        let skill = try resolver.skill(slug)
        try requireSavedDraft(skill)
        let library = runtime.library, platform = runtime.platformVM
        guard !library.libraryUnavailable else {
            return .failure("store_unreadable", library.persistentFenceReason ?? "The library is unavailable.",
                hint: "Relaunch Pensieve and try again.", exit: 1)
        }
        let projects = try context.fetch(FetchDescriptor<Project>())
        let preview = platform.removeAllDeploys(skill: skill, projects: projects, dryRun: true) {
            try platform.localSkillProjectDeployEvidence(skill: skill, projects: projects, context: context, readOnly: true)
        }
        var fields = try deletionValue(skill, preview: preview)
        let data = CLIValue.object(fields)
        if preview.batch.hasFailures {
            var envelope = CLIReply.failure("deletion_refused", preview.batch.readFailures.map(\.message).joined(separator: " "),
                hint: "Resolve the deployment record problem in Pensieve and retry.", exit: 1).envelope
            envelope.data = data
            return CLIReply(envelope: envelope, exitCode: 1)
        }
        if let reply = try previewOrConfirmation(data, options: options) { return reply }
        var changed = false
        let skillID = skill.id
        let presentation = SkillLibraryViewModel.DeletionPresentation(presentsInWindow: false)
        let completed = SkillDeletionFlow.delete(skill: skill, library: library, platformVM: platform,
            projects: projects, context: context, reportChanges: { changed = $0 }, presentation: presentation)
        if completed { runtime.upstreamHistory.remove(skillID: skillID) }
        await library.manifestSaves?.waitUntilIdle()
        let remaining = try context.fetch(FetchDescriptor<Skill>()).first { $0.directoryName == slug }
        let remainingPaths = preview.plannedRemovals.filter { files.fileExists(at: $0.artifactPath)
            || files.isSymlink(at: $0.artifactPath) }.map(\.artifactPath)
        if !completed || deletionFailed(presentation.notice) {
            var envelope = CLIReply.failure(changed ? "partial" : "deletion_refused",
                presentation.notice?.message ?? "Deletion did not complete.",
                hint: "Inspect the remaining skill and deployments in Pensieve before retrying.", exit: 1).envelope
            envelope.changed = changed
            envelope.data = .object(["plan": data, "skillRetained": .bool(remaining != nil),
                "remainingDeployments": .array(remainingPaths.map(CLIValue.string))])
            return CLIReply(envelope: envelope, exitCode: 1)
        }
        fields["warnings"] = .array(presentation.notice.map { [.string($0.message)] } ?? [])
        return success(.object(fields), changed: true)
    }
    private func deletionValue(_ skill: Skill, preview: SkillCleanupResult) throws -> [String: CLIValue] {
        let slug = skill.directoryName
        let intents = try context.fetch(FetchDescriptor<MachineDeployIntent>(
            predicate: #Predicate { $0.skillSlug == slug })).map(\.key).sorted()
        let categories = try context.fetch(FetchDescriptor<Category>())
            .filter { $0.skillSlugs.contains(slug) }.map { $0.id.uuidString }.sorted()
        return ["slug": .string(slug), "id": .string(skill.id.uuidString),
            "installedCommit": skill.installedOrigin.map { .string($0.installedCommit) } ?? .null,
            "intents": .array(intents.map(CLIValue.string)), "categories": .array(categories.map(CLIValue.string)),
            "deployments": .array(preview.plannedRemovals.sorted { $0.artifactPath < $1.artifactPath }.map {
            .object(["agent": .string($0.platform.cliID), "path": .string($0.artifactPath),
                "project": $0.projectPath.map(CLIValue.string) ?? .null])
        })]
    }

}
