import Foundation
import SwiftData
import SwiftUI

@Observable
final class SkillLibraryViewModel {
    enum SkillDeletionResult: Equatable {
        case deleted
        /// Deleted, but the manifest rewrite failed (`error` carries the message); the manifest lags until the next mutation.
        case deletedManifestStale
        /// `skillStore.deleteSkill` threw; the directory and the row are both still there. The pending
        /// edit was already cancelled.
        case retainedDirectoryDeleteFailed(String)
        /// The directory is gone but the row save threw: the context was rolled back and the row is quarantined in
        /// `pendingRowCleanup` (no write path recreates its files; the detail column shows a placeholder) until a
        /// retry from the list or the launch rebuild drops it. Never left as a pending unsaved deletion.
        case directoryDeletedRowRetained(String)
    }

    enum DeletionNotice: Equatable {
        case failed(String)
        case pending(String)
        case warning(String)

        var title: String {
            switch self {
            case .failed: "Couldn't delete skill"
            case .pending: "Skill files removed; library cleanup pending"
            case .warning: "Skill deleted with a warning"
            }
        }

        var message: String {
            switch self {
            case let .failed(message), let .pending(message), let .warning(message): message
            }
        }
    }

    let skillStore: SkillStoreProtocol
    let fileService: FileServiceProtocol
    /// The self-write fingerprint by slug: the body the app last wrote or loaded, in the store's canonical form
    /// (`SkillParser.canonicalBody`). NOT observed: the install and update finalizers mutate it off the main thread
    /// under `fingerprintLock`, and an observed mutation there would take SwiftUI's update lock while holding ours,
    /// against a `body` that takes ours while holding SwiftUI's (`hasUnsavedChanges`) — an ABBA deadlock the batch
    /// Layer-2 reproduced. Views that show dirtiness observe the main-thread signals instead: `drafts`, `reloadToken`,
    /// `externallyModified`, `appWriteRevision`.
    @ObservationIgnored var lastWrittenBody: [String: String] = [:]
    @ObservationIgnored let fingerprintLock = NSLock()
    @ObservationIgnored var pendingAppWrittenBody: [String: String] = [:]
    @ObservationIgnored var appWritePublishQueued = false
    /// Monotonic invalidation for successful app-authored SKILL.md rewrites (frontmatter-only ones included).
    @MainActor private(set) var appWriteRevision: Int = 0
    let fileWatchService: FileWatchServiceProtocol
    private let manifestService: ManifestSnapshotting?
    private let manifestRoot: String
    private var lastManifestError: String?
    let notifier: SyncStateNotifying
    var isWatching = false
    var isApplyingCoordinatorChanges = false
    var coordinatorBaselineBodies: [String: String] = [:]
    var coordinatorObservedSlugs: Set<String> = []
    var watcherEventSequence: UInt64 = 0
    /// Asset invalidation belongs to the folder reported by the watcher, even for a body echo.
    var folderChangeRevisions: [String: UInt64] = [:]
    var error: String?
    var showCreateSheet = false
    /// Skill `directoryName`s whose on-disk body changed outside the app and have not yet been re-edited.
    var externallyModified: Set<String> = []
    /// The unsaved editor drafts by slug — an entry enters when the editor's text differs from the file's last
    /// known body and leaves on Save, Revert, deletion, or typing back to it; whether it is dirty now is measured
    /// against the fingerprint (edits reach disk only on Save). `SkillLibraryViewModel+Draft.swift`.
    var drafts: [String: EditorDraft] = [:]
    /// The one unsaved-changes question open, if any, and what a leaving question does with the answer.
    var pendingUnsavedChanges: UnsavedChangesPrompt?
    @ObservationIgnored var pendingLeaveContinuation: ((Bool) -> Void)?
    /// Shows the stock sheet and reports the answer. The app wires `UnsavedChangesAlert.present`
    /// (`PensieveApp.init`); the default answers Cancel, so a headless library never writes or discards on
    /// its own — a test injects a recorder.
    @ObservationIgnored var unsavedChangesPresenter: (UnsavedChangesPrompt, @escaping (UnsavedChangesChoice) -> Void) -> Void =
        { _, resolve in resolve(.cancel) }
    /// Monotonically bumped whenever an external change is accepted, so the editor can re-run loadBody().
    private(set) var reloadToken: Int = 0
    /// A discard or a restore: a mounted, clean editor reloads the file on the next token.
    func noteEditorBodyInvalidated() { reloadToken &+= 1 }
    /// Rows whose SKILL.md is not a readable regular file — the files-gone/row-retained state.
    private(set) var pendingRowCleanup: Set<UUID> = []
    /// The Skill rows could not be fetched: nothing is trusted and every write guard refuses.
    private(set) var libraryUnavailable = false
    /// The last rebuild could not read the manifest (newer schema or corrupt): adds are fenced.
    private(set) var storeUnreadable = false
    var deletionNotice: DeletionNotice?
    init(
        skillStore: SkillStoreProtocol? = nil,
        fileService: FileServiceProtocol? = nil,
        fileWatchService: FileWatchServiceProtocol? = nil,
        manifestService: ManifestSnapshotting? = nil,
        manifestRoot: String = Constants.pensieveBaseDir,
        notifier: @escaping SyncStateNotifying = SyncStateNotifier.suppressed
    ) {
        let fs = fileService ?? FileService()
        self.fileService = fs
        self.skillStore = skillStore ?? SkillStore(fileService: fs)
        self.fileWatchService = fileWatchService ?? FileWatchService()
        self.manifestService = manifestService
        self.manifestRoot = manifestRoot
        self.notifier = notifier
    }
    deinit {
        fileWatchService.stop()
    }
    // MARK: - CRUD
    /// Best-effort: regenerate the on-disk manifest from current SwiftData state after a mutation to
    /// synced state. No-op when no manifest service is wired (tests). A failure is SURFACED via `error`,
    /// never silently swallowed (the mutation itself already succeeded and is not rolled back).
    func regenerateManifest(context: ModelContext) {
        do {
            try writeManifest(context: context)
        } catch {
            let message = "Saved, but updating the sync manifest failed: \(error.localizedDescription)"
            self.error = message
            lastManifestError = message
        }
    }

    func writeManifest(context: ModelContext) throws {
        guard let manifestService else { return }
        try manifestService.write(manifestService.snapshot(from: context), toRoot: manifestRoot)
        if error == lastManifestError { error = nil }
        lastManifestError = nil
    }

    @discardableResult
    func createSkill(
        name: String,
        description: String,
        body: String,
        tags: [String],
        context: ModelContext,
        takenSlugs: (ModelContext) throws -> Set<String> = { Set(try $0.fetch(FetchDescriptor<Skill>()).map(\.directoryName)) }
    ) -> Skill? {
        guard !libraryUnavailable, !storeUnreadable else {
            self.error = libraryUnavailable
                ? "Failed to create skill: the library couldn't be read" : Self.storeUnreadableMessage
            return nil
        }
        do {
            let taken = try takenSlugs(context)
            let resolvedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? name
                : description
            let dirName = try skillStore.createSkill(
                name: name, description: resolvedDescription, body: body, avoiding: taken)
            let skill = Skill(
                name: name,
                skillDescription: resolvedDescription,
                tags: tags,
                scope: .user,
                directoryName: dirName
            )
            context.insert(skill)
            try context.save()
            error = nil
            regenerateManifest(context: context)
            setLastWrittenBody(SkillParser.canonicalBody(body), directoryName: dirName)
            notifier()
            return skill
        } catch {
            self.error = "Failed to create skill: \(error.localizedDescription)"
            return nil
        }
    }

}

extension SkillLibraryViewModel {
    /// Delete a skill's files and its row — nothing else. Callers retire memberships/ledgers/intent first.
    /// Never nudges sync; the caller does, once, after its own authoritative manifest write.
    @discardableResult
    // Frozen 26.2-a keeps the pre-delete probe and both existing re-probes in this one primitive.
    func deleteSkillEntry(_ skill: Skill, context: ModelContext,
                          persist: (ModelContext) throws -> Void = { try $0.save() }) -> SkillDeletionResult {
        let quarantined = pendingRowCleanup.contains(skill.id)
        if quarantined {
            // Probe BEFORE any destructive step: a retry proceeds only when the leaf is not readable and the
            // no-follow, case-folded listing proves the entry absent. Any entry retains; a readable regular
            // file also lifts the quarantine; an enumeration failure (nil) retains and keeps it.
            let readable = hasReadableSkillFile(skill.directoryName)
            let entryPresent = try? skillStore.slugEntryExists(skill.directoryName)   // nil = couldn't enumerate
            if readable || entryPresent != false {
                if readable { pendingRowCleanup.remove(skill.id) }
                let detail = readable ? "the skill's files are present"
                    : (entryPresent == true ? "the skill's entry is still present" : "couldn't verify the entry is gone")
                self.error = "Failed to delete skill: \(detail)"
                return .retainedDirectoryDeleteFailed(detail)
            }
        }
        do {
            try skillStore.deleteSkill(directoryName: skill.directoryName)
        } catch {
            // A quarantined row's files are normally already gone (deleteDirectory throws on an absent path).
            // Proceed only when the slug is provably absent at these probes — the leaf first, then the name
            // through a no-follow, case-folded listing: any entry retains; a readable regular file also lifts
            // the quarantine; an enumeration failure (nil) retains and keeps it.
            let readable = hasReadableSkillFile(skill.directoryName)
            let entryPresent = try? skillStore.slugEntryExists(skill.directoryName)   // nil = couldn't enumerate
            let filesGone = quarantined && entryPresent == false && !readable
            if !filesGone {
                if readable { pendingRowCleanup.remove(skill.id) }
                let detail = error.localizedDescription
                self.error = "Failed to delete skill: \(detail)"
                return .retainedDirectoryDeleteFailed(detail)
            }
        }
        if quarantined {                                            // one last look before the row goes — both probes again
            let reappeared = hasReadableSkillFile(skill.directoryName)
            if reappeared || (try? skillStore.slugEntryExists(skill.directoryName)) != false {
                if reappeared { pendingRowCleanup.remove(skill.id) }   // a readable regular file always lifts
                self.error = "Failed to delete skill: the skill's files reappeared"
                return .retainedDirectoryDeleteFailed("the skill's files reappeared")
            }
        }
        // The draft goes only once the files are provably gone: Delete asks no unsaved-changes sheet (PLAN-34), a
        // retained entry can turn dirty while the confirmation is up (a sync pull), and a delete refused above retains
        // the skill WITH its draft (PLAN-33 batch Layer-2).
        discardDraft(skill)
        setLastWrittenBody("", directoryName: skill.directoryName)   // files are gone: the watcher's echo is ours
        context.delete(skill)
        do {
            try persist(context)
        } catch {
            context.rollback()
            let detail = error.localizedDescription
            pendingRowCleanup.insert(skill.id)
            reloadToken &+= 1
            self.error = "Removed the skill's files, but couldn't save the library change: \(detail)"
            return .directoryDeletedRowRetained(detail)
        }
        pendingRowCleanup.remove(skill.id)
        self.error = nil
        regenerateManifest(context: context)
        return self.error == nil ? .deleted : .deletedManifestStale
    }
}

extension SkillLibraryViewModel {
    func isWriteFenced(_ skill: Skill) -> Bool { libraryUnavailable || pendingRowCleanup.contains(skill.id) }
    /// Launch ingestion's verdict (`AppRuntime.acceptLaunchIngest`), on every accepted outcome.
    func setStoreUnreadable(_ unreadable: Bool) { applyFence(unreadable) }

    /// `.synced` and `.conflicted` both passed the engine's pre-write read (an aborted rebase restores the
    /// pre-pull tree), so either lifts the fence; a refused store drops it; the rest never prove a read.
    func applySyncCycleOutcome(_ result: SyncCycleResult) {
        switch result {
        case .synced, .conflicted: applyFence(false)
        case .storeUnreadable: applyFence(true)
        case .noRemote, .locked, .failed: break
        }
    }

    /// A rising fence closes the create sheet here; the view closes its own sheets on `addsFenced`.
    private func applyFence(_ unreadable: Bool) {
        storeUnreadable = unreadable
        if unreadable { showCreateSheet = false }
    }

    /// C7-safe presence: true only when the slug's SKILL.md is a readable regular file.
    func hasReadableSkillFile(_ directoryName: String) -> Bool {
        (try? skillStore.readBody(directoryName: directoryName)) != nil
    }

    /// Recompute the quarantine from disk with the C7-safe probe. A fetch that throws flips
    /// `libraryUnavailable` instead; the `fetch` seam exists for that failure test.
    func refreshQuarantine(context: ModelContext,
                           fetch: (ModelContext) throws -> [Skill] = { try $0.fetch(FetchDescriptor<Skill>()) }) {
        do {
            let rows = try fetch(context)
            libraryUnavailable = false
            pendingRowCleanup = Set(rows.filter { !hasReadableSkillFile($0.directoryName) }.map(\.id))
        } catch {
            libraryUnavailable = true
        }
    }

    func acceptExternalChange(directoryName: String, currentBody: String, shouldNotify: Bool) {
        // The fingerprint moves to what the file holds now, so a repeat event is an echo. A clean editor
        // reloads on the token; a dirty one keeps its draft and the view model asks what to do with it —
        // here, not in a view, because in the default Preview mode no editor is mounted (PLAN-02 / 02.3).
        // Dirty is measured against the new fingerprint, so a draft the file has caught up with has nothing
        // to save and nothing is dropped; during a sync cycle the question waits for the cycle's final body
        // (`finishCoordinatorChanges`) — a transient body must not cost the draft or ask about itself.
        setLastWrittenBody(currentBody, directoryName: directoryName)
        externallyModified.insert(directoryName)
        reloadToken &+= 1
        if !isApplyingCoordinatorChanges, hasUnsavedChanges(forDirectory: directoryName) {
            requestUnsavedChangesPrompt(directoryName: directoryName, reason: .externalChange)
        }
        if shouldNotify { notifier() }
    }
}

extension SkillLibraryViewModel {
    func publishAppWriteRevision() {
        // Detached install/update finalizers call this off-main: the counter hops to main, and publishes
        // queued before the next main-queue drain coalesce into one revision bump.
        let alreadyQueued: Bool = withFingerprintLock {
            defer { appWritePublishQueued = true }
            return appWritePublishQueued
        }
        guard !alreadyQueued else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.withFingerprintLock { self.appWritePublishQueued = false }
            self.appWriteRevision &+= 1
        }
    }

}
