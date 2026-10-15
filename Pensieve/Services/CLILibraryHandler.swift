import CryptoKit
import Foundation
import SwiftData

@MainActor
struct CLILibraryHandler {
    let runtime: AppRuntime
    let files: FileServiceProtocol
    var context: ModelContext { runtime.container.mainContext }
    var resolver: CLINameResolver { CLINameResolver(context: context, files: files) }

    func handle(_ request: CLIRequest) async -> CLIReply {
        do {
            let options = request.library ?? CLILibraryOptions()
            switch request.command {
            case "install": return try await install(request.arguments.first ?? "", options: options)
            case "skill outdated": return try await outdated()
            case "skill update": return try await update(request.arguments, options: options)
            case "skill delete": return try await delete(request.arguments.first ?? "", options: options)
            case "project add": return try await addProject(request.arguments.first ?? "", options: options)
            case "project remove": return try removeProject(request.arguments.first ?? "", options: options)
            default: return .failure("usage", "Unknown library command.", hint: "Run pensieve commands.", exit: 64)
            }
        } catch let refusal as CLICommandRefusal { return refusal.reply } catch {
            return failure(error)
        }
    }

    func requireAddsAllowed() throws {
        if let reason = runtime.library.addFenceReason {
            throw CLICommandRefusal(reply: .failure("store_unreadable", reason,
                hint: "Resolve the library problem in Pensieve, then retry.", exit: 1))
        }
    }

    func requireSavedDraft(_ skill: Skill) throws {
        if runtime.library.hasUnsavedChanges(for: skill) {
            throw CLICommandRefusal(reply: .failure("unsaved_draft", "\(skill.directoryName) has unsaved edits in Pensieve.",
                hint: "Save or discard the draft in Pensieve first.", exit: 5))
        }
    }

    func previewOrConfirmation(_ data: CLIValue, options: CLILibraryOptions) throws -> CLIReply? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let token = SHA256.hash(data: try encoder.encode(data)).map { String(format: "%02x", $0) }.joined()
        if options.dryRun {
            var envelope = CLIReply.success(data).envelope
            envelope.confirmationToken = token
            return CLIReply(envelope: envelope, exitCode: 0)
        }
        if options.confirmed, options.confirmationToken == nil || options.confirmationToken == token { return nil }
        var envelope = CLIReply.failure("confirmation_required", "Review this plan before applying it.",
            hint: "Confirm with --yes.", exit: 5).envelope
        envelope.data = data
        envelope.confirmationToken = token
        envelope.changed = false
        return CLIReply(envelope: envelope, exitCode: 5)
    }

    func success(_ data: CLIValue, changed: Bool) -> CLIReply {
        var envelope = CLIReply.success(data).envelope
        envelope.changed = changed
        return CLIReply(envelope: envelope, exitCode: 0)
    }

    func failure(_ error: Error, changed: Bool = false, data: CLIValue? = nil) -> CLIReply {
        let busy = error as? SkillInstallError == .syncInProgress || error as? SyncError == .syncInProgress
        let drift = error as? SkillUpdateFlowError == .localEditsRequireConfirmation
        let partial = changed || error is SyncedStateMutationError
        let code = partial ? "partial" : (busy ? "sync_running" : (drift ? "local_changes" : "operation_failed"))
        var envelope = CLIReply.failure(code, error.localizedDescription,
            hint: drift ? "Review the edits, then pass --overwrite-local-changes to replace them."
                : "Inspect the result in Pensieve before trying again.", exit: 1, retryable: busy && !partial).envelope
        envelope.changed = partial
        envelope.data = data
        return CLIReply(envelope: envelope, exitCode: 1)
    }

    func projectValue(_ project: Project) -> CLIValue {
        .object(["id": .string(project.id.uuidString), "name": .string(project.name), "path": .string(project.path),
            "identity": project.identityKey.map(CLIValue.string) ?? .null])
    }
}
