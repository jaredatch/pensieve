import Foundation
import SwiftData

extension ManifestSaveModel {
    static let waitingForRepairMessage = "The library file is damaged. This change waits for its repair."
    static let changedRepairMessage = "The library file changed. Review the repair again."
    var damageAlertMessage: String {
        repairError == Self.changedRepairMessage ? Self.changedRepairMessage + "\n\n" + Self.damageMessage : Self.damageMessage
    }
    func deletionWaitsForRepair(_ slug: String) -> Bool {
        libraryDamaged && items.contains {
            if case .deleteSkill(let waiting) = $0.change { return waiting == slug }
            return false
        }
    }
    static let damageTitle = "The synced library file is damaged"
    static let damageMessage = "Your change is kept on this Mac and saves once the file is repaired. "
        + "Replacing the file with this Mac's library repairs it now."
    static let repairAction = "Replace with This Mac's Library…"
    static let repairTitle = "Replace the synced library with this Mac's?"
    static let repairMessage = "Pensieve rewrites the damaged file from the skills, categories and deployments on this Mac. "
        + "Changes other Macs synced that this Mac hasn't read are lost."

    private enum LibraryRead { case readable, damaged, newer }

    func acceptLibraryVerdict(newer: Bool) {
        damageObservationOrder += 1
        requiresNewerVersion = newer
    }

    /// Later-started reads and accepted launch/sync verdicts supersede this observation.
    @MainActor
    func refreshDamage() async {
        damageObservationOrder += 1
        let order = damageObservationOrder
        let pending = items.contains {
            StoreIngestState.shared(for: $0.presentation.context.container).needsRebuild
        }
        let root = root, files = files, manifest = manifest
        let observation = await BlockingWork.run { () -> (LibraryRead, ManifestDamage?) in
            do {
                _ = try manifest.read(fromRoot: root)
                if pending, !files.fileExists(at: root + "/manifest/manifest.yaml") {
                    return (.damaged, ManifestDamage.capture(root: root, files: files))
                }
                return (.readable, nil)
            } catch {
                if case ManifestError.unsupportedSchema = error { return (.newer, nil) }
                return (.damaged, ManifestDamage.capture(root: root, files: files))
            }
        }
        guard order == damageObservationOrder else { return }
        let wasDamaged = libraryDamaged
        libraryDamaged = observation.0 == .damaged
        requiresNewerVersion = observation.0 == .newer
        if !showsDamageAlert, !showsRepairConfirmation { damage = observation.1 }
        if wasDamaged, observation.0 == .readable { didReadRepairedLibrary() }
    }

    @MainActor
    func refreshAndRetry() async {
        await refreshDamage()
        guard !libraryDamaged else { return }
        retryWaitingEdits()
    }

    @MainActor
    func requestRepair() {
        repairError = nil
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
        defer { held?.release(); isWaiting = false; if libraryDamaged { pausedForRepair = true } }
        do {
            guard let expected else { throw ManifestError.damaged }
            pausedForRepair = false
            held = try await takeLock()
            let snapshot = try manifest.snapshot(from: context)
            let captured = Set(items.filter { $0.presentation.context === context }.map(\.id))
            let root = root, manifest = manifest
            let wrote = try await BlockingWork.run {
                try manifest.repair(snapshot, root: root, replacing: expected)
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
            if !wrote, libraryDamaged {
                repairError = Self.changedRepairMessage
                showsDamageAlert = true
            }
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
