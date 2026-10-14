import Foundation

@MainActor
struct CLISyncHandler {
    let model: SyncModel

    func handle() async -> CLIReply {
        let result = await model.syncCycleForCommand()
        switch result {
        case let .synced(pushed, warnings, _, _, pulled):
            return CLIReply(envelope: CLIEnvelope(ok: true, changed: pushed || pulled,
                data: .object(["result": .string("synced"), "pushed": .bool(pushed), "pulled": .bool(pulled),
                    "warnings": .array(warnings.map(CLIValue.string))])), exitCode: 0)
        case let .conflicted(paths):
            var envelope = CLIReply.failure("conflict", "Sync needs conflict resolution.",
                hint: "Resolve the conflicts in Pensieve, then run pensieve sync.", exit: 5).envelope
            envelope.data = .object(["paths": .array(paths.map(CLIValue.string))])
            return CLIReply(envelope: envelope, exitCode: 5)
        case .noRemote:
            return .failure("not_connected", "Pensieve is not connected to a sync remote.",
                hint: "Connect a remote in Pensieve's Settings.", exit: 1)
        case .branchless:
            return .failure("sync_failed", "Pensieve's library has no sync history.", hint: "Check sync in Pensieve.", exit: 1)
        case .locked:
            return .failure("sync_running", "Another process holds the sync lock.", hint: "Wait for sync to finish.",
                exit: 1, retryable: true)
        case let .failed(message):
            return .failure("sync_failed", message, hint: "Follow the app's advice and retry Sync Now.", exit: 1)
        case let .storeUnreadable(message):
            return .failure("store_unreadable", message, hint: "Open Pensieve to check the library.", exit: 1)
        }
    }
}
