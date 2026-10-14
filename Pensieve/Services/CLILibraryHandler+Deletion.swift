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
        let data: CLIValue = .object(["slug": .string(slug), "deployments": .array(preview.plannedRemovals.map {
            .object(["agent": .string($0.platform.cliID), "path": .string($0.artifactPath),
                "project": $0.projectPath.map(CLIValue.string) ?? .null])
        })])
        if preview.batch.hasFailures {
            var envelope = CLIReply.failure("deletion_refused", preview.batch.readFailures.map(\.message).joined(separator: " "),
                hint: "Resolve the deployment record problem in Pensieve and retry.", exit: 1).envelope
            envelope.data = data
            return CLIReply(envelope: envelope, exitCode: 1)
        }
        if let reply = previewOrConfirmation(data, options: options) { return reply }
        var changed = false
        let completed = SkillDeletionFlow.delete(skill: skill, library: library, platformVM: platform,
            projects: projects, context: context, reportChanges: { changed = $0 })
        await library.manifestSaves?.waitUntilIdle()
        let remaining = try context.fetch(FetchDescriptor<Skill>()).first { $0.directoryName == slug }
        let remainingPaths = preview.plannedRemovals.filter { files.fileExists(at: $0.artifactPath)
            || files.isSymlink(at: $0.artifactPath) }.map(\.artifactPath)
        if !completed || deletionFailed(library.deletionNotice) {
            var envelope = CLIReply.failure(changed ? "partial" : "deletion_refused",
                library.deletionNotice?.message ?? "Deletion did not complete.",
                hint: "Inspect the remaining skill and deployments in Pensieve before retrying.", exit: 1).envelope
            envelope.changed = changed
            envelope.data = .object(["plan": data, "skillRetained": .bool(remaining != nil),
                "remainingDeployments": .array(remainingPaths.map(CLIValue.string))])
            return CLIReply(envelope: envelope, exitCode: 1)
        }
        return success(data, changed: true)
    }
}
