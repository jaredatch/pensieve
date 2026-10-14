import Foundation
import SwiftData

extension CLILibraryHandler {
    func outdated() async throws -> CLIReply {
        if let error = await runtime.checkForSkillUpdatesAndReport() {
            return .failure("update_check_failed", error, hint: "Check your connection and GitHub token, then retry.", exit: 1)
        }
        let container = runtime.container
        let (errors, rows) = try await BlockingWork.run {
            let context = ModelContext(container)
            let skills = try context.fetch(FetchDescriptor<Skill>())
            let errors = skills.compactMap { skill in skill.checkError.map { skill.directoryName + ": " + $0 } }
            let rows: [CLIValue] = skills.filter(UpdatesViewModel.isEligibleForUpdates).map {
                .object(["slug": .string($0.directoryName), "commit": $0.upstreamCommit.map(CLIValue.string) ?? .null])
            }
            return (errors, rows)
        }
        let data: CLIValue = .object(["skills": .array(rows), "errors": .array(errors.map(CLIValue.string))])
        guard errors.isEmpty else {
            var envelope = CLIReply.failure("update_check_failed", errors.joined(separator: " "),
                hint: "Check the source repositories and GitHub token, then retry.", exit: 1).envelope
            envelope.data = data
            return CLIReply(envelope: envelope, exitCode: 1)
        }
        return .success(data)
    }

    func update(_ slugs: [String], options: CLILibraryOptions) async throws -> CLIReply {
        guard !runtime.library.libraryUnavailable else {
            return .failure("store_unreadable", runtime.library.persistentFenceReason ?? "The library is unavailable.",
                hint: "Relaunch Pensieve and try again.", exit: 1)
        }
        let skills = try Array(Set(slugs)).sorted().map(resolver.skill)
        for skill in skills { try requireSavedDraft(skill) }
        let model = runtime.updates
        guard !model.isApplying, !model.commandApplyInFlight else { return updateBusyReply }
        // Reserve admission through planning and apply. The window observes the same gate.
        model.commandApplyInFlight = true
        defer { model.commandApplyInFlight = false }
        let operations = runtime.updatesViewModelOperations, container = runtime.container
        let plans = try await BlockingWork.run {
            try operations.updateCheckService.planUpdates(slugs: Set(slugs), context: ModelContext(container))
        }
        for skill in skills { try requireSavedDraft(skill) }
        let data: CLIValue = .object(["skills": .array(plans.map { plan in
            .object(["slug": .string(plan.slug), "action": .string(plan.update == nil ? "unchanged" : "update"),
                "commit": plan.update.map { .string($0.source.headCommit) } ?? .null,
                "drifted": .bool(plan.drifted), "installedCommit": .string(plan.origin.installedCommit)])
        })])
        for plan in plans {
            if let update = plan.update {
                _ = try await BlockingWork.run { try operations.skillInstallService.previewUpdate(update) }
            }
        }
        if let reply = try previewOrConfirmation(data, options: options) { return reply }
        if plans.contains(where: { $0.update != nil && $0.drifted }), !options.overwriteLocalChanges {
            throw SkillUpdateFlowError.localEditsRequireConfirmation
        }
        return await applyPlans(plans, options: options, data: data)
    }

    private func applyPlans(_ plans: [SkillUpdatePlan], options: CLILibraryOptions, data: CLIValue) async -> CLIReply {
        let operations = runtime.updatesViewModelOperations, container = runtime.container
        let model = runtime.updates
        var applied: [String] = []
        let registration = runtime.syncBodyWriteRegistration
        for plan in plans {
            guard let update = plan.update else { continue }
            do {
                try requireSavedDraft(try resolver.skill(plan.slug))
                let completion = try await BlockingWork.run {
                    try operations.skillInstallService.applyAndReport(update, expectedOrigin: plan.origin,
                        allowLocalOverwrite: options.overwriteLocalChanges, registration: registration,
                        context: ModelContext(container))
                }
                model.applyCompletion(completion, context: context)
                runtime.syncWriteEchoRegistrar([plan.slug])
                runtime.library.noteEditorBodyInvalidated()
                runtime.syncStateNotifier()
                applied.append(plan.slug)
            } catch {
                if error is SyncedStateMutationError {
                    runtime.syncWriteEchoRegistrar([plan.slug])
                    runtime.library.noteEditorBodyInvalidated()
                    runtime.syncStateNotifier()
                }
                if let refusal = error as? CLICommandRefusal, applied.isEmpty { return refusal.reply }
                return failure(error, changed: !applied.isEmpty,
                    data: .object(["plan": data, "updated": .array(applied.map(CLIValue.string))]))
            }
        }
        return success(data, changed: !applied.isEmpty)
    }

    private var updateBusyReply: CLIReply {
        var envelope = CLIReply.failure("update_in_progress", "Pensieve is applying skill updates.",
            hint: "Wait for the updates to finish, then retry.", exit: 1, retryable: true).envelope
        envelope.changed = false
        return CLIReply(envelope: envelope, exitCode: 1)
    }
}
