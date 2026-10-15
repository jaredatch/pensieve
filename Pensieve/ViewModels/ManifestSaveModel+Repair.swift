import Foundation
import SwiftData

extension ManifestSaveModel {
    static let damageTitle = "The synced library file is damaged"
    static let damageMessage = "Your change is kept on this Mac and saves once the file is repaired. "
        + "Replacing the file with this Mac's library repairs it now."
    static let repairAction = "Replace with This Mac's Library…"
    static let repairTitle = "Replace the synced library with this Mac's?"
    static let repairMessage = "Pensieve rewrites the damaged file from the skills, categories and deployments on this Mac. "
        + "Changes other Macs synced that this Mac hasn't read are lost."

    /// Launch, cycle completion and the sidebar refresh derive damage from disk, including after relaunch.
    @MainActor
    func refreshDamage() async {
        let root = root, files = files, manifest = manifest
        let observation = await BlockingWork.run { () -> (Bool, ManifestDamage?) in
            do {
                _ = try manifest.read(fromRoot: root)
                return (false, nil)
            } catch {
                if case ManifestError.unsupportedSchema = error { return (false, nil) }
                return (true, try? ManifestDamage.capture(root: root, files: files))
            }
        }
        libraryDamaged = observation.0
        if !showsDamageAlert, !showsRepairConfirmation { damage = observation.1 }
        if !libraryDamaged, !items.isEmpty {
            let pendingMissing = items.contains {
                StoreIngestState.shared(for: $0.presentation.context.container).needsRebuild
            }
            let token = await BlockingWork.run { try? ManifestDamage.capture(root: root, files: files) }
            if pendingMissing, token?.missing == true {
                libraryDamaged = true
                if !showsDamageAlert, !showsRepairConfirmation { damage = token }
            }
        }
    }

    @MainActor
    func refreshAndRetry() async {
        await refreshDamage()
        guard !libraryDamaged else { return }
        retryWaitingEdits()
    }

    @MainActor
    func requestRepair() {
        confirmedDamage = damage
        showsDamageAlert = false
        showsRepairConfirmation = true
    }

    @MainActor
    func cancelRepair() {
        confirmedDamage = nil
        showsRepairConfirmation = false
    }

    @MainActor
    func replaceWithThisMac(context: ModelContext) async {
        let expected = confirmedDamage
        cancelRepair()
        repairError = nil
        var held: SyncLock?
        defer { held?.release(); isWaiting = false }
        do {
            guard let expected else { throw ManifestError.damaged }
            held = try await takeLock()
            let snapshot = try manifest.snapshot(from: context)
            let captured = Set(items.filter { $0.presentation.context === context }.map(\.id))
            let root = root, files = files
            let wrote = try await BlockingWork.run {
                try ManifestService(fileService: files).repair(snapshot, root: root, replacing: expected)
            }
            if wrote {
                for index in items.indices where captured.contains(items[index].id) { items[index].wasHealed = true }
                let ingest = StoreIngestState.shared(for: context.container)
                for id in captured { ingest.finish(id) }
                ingest.invalidate()
                didSave()
            }
            held?.release()
            await refreshAndRetry()
        } catch {
            repairError = error.localizedDescription
            await refreshDamage()
        }
    }

    @MainActor
    private func retryWaitingEdits() {
        guard worker == nil, !items.isEmpty else { return }
        worker = Task { @MainActor in await self.drain() }
    }
}
