import Foundation
import SwiftData

extension CLILibraryHandler {
    func install(_ url: String, options: CLILibraryOptions) async throws -> CLIReply {
        try requireAddsAllowed()
        let service = runtime.updatesViewModelOperations.skillInstallService
        let container = runtime.container
        let plan = try await BlockingWork.run {
            try service.plan(url: url, skills: options.skills, rename: options.rename, skip: options.skip,
                context: ModelContext(container))
        }
        try requireAddsAllowed()
        let data = installValue(plan)
        if options.dryRun, let reply = try previewOrConfirmation(data, options: options) { return reply }
        if plan.entries.contains(where: { $0.action == "collision" }) {
            var envelope = CLIReply.failure("slug_collision", "A selected skill's slug is already taken.",
                hint: "Use --rename to choose a free slug, or --skip to leave collisions alone.", exit: 5).envelope
            envelope.data = data
            envelope.changed = false
            return CLIReply(envelope: envelope, exitCode: 5)
        }
        if let reply = try previewOrConfirmation(data, options: options) { return reply }
        var installed: [String] = []
        let registration = runtime.syncBodyWriteRegistration
        for entry in plan.entries where entry.action == "install" {
            do {
                try requireAddsAllowed()
                let result = try await BlockingWork.run {
                    try service.install(candidate: entry.candidate, renamedTo: entry.slug, from: plan.source,
                        bodyWriteRegistration: registration, context: ModelContext(container))
                }
                guard case .installed = result else {
                    throw SkillInstallError.unavailableCandidate(
                        "The slug \(entry.slug) became occupied. Preview the install again.")
                }
                installed.append(entry.slug)
                runtime.syncWriteEchoRegistrar([entry.slug])
                runtime.syncStateNotifier()
            } catch {
                if error is SyncedStateMutationError { runtime.syncStateNotifier() }
                return failure(error, changed: !installed.isEmpty,
                    data: .object(["plan": data, "installed": .array(installed.map(CLIValue.string))]))
            }
        }
        return success(data, changed: !installed.isEmpty)
    }

    private func installValue(_ plan: SkillInstallPlan) -> CLIValue {
        .object(["repo": .string(plan.source.repo), "commit": .string(plan.source.headCommit),
            "skills": .array(plan.entries.map { entry in
                .object(["slug": .string(entry.slug), "path": .string(entry.candidate.path),
                    "action": .string(entry.action)])
            })])
    }
}
