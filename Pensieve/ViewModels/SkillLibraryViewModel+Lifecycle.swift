import Foundation
import SwiftData

extension SkillLibraryViewModel {

    func updateMetadata(_ skill: Skill, tags: [String], scope: SkillScope, context: ModelContext) {
        // A commit that lands after the row's deletion was SAVED sees `isDeleted == false` on a detached
        // object (SwiftData resets it) — the context identity is the check that still holds. Writing
        // would regenerate the manifest and nudge sync for a skill that no longer exists (30.1 Layer-2).
        guard !skill.isDeleted, skill.modelContext === context else { return }
        let previousTags = skill.tags, previousScope = skill.scope, previousUpdatedAt = skill.updatedAt
        skill.tags = tags
        skill.scope = scope
        skill.updatedAt = Date()
        do {
            try context.save()
            error = nil
            regenerateManifest(context: context)
            notifier()
        } catch {
            skill.tags = previousTags
            skill.scope = previousScope
            skill.updatedAt = previousUpdatedAt
            self.error = "Failed to update skill: \(error.localizedDescription)"
        }
    }

    /// Treat watcher events produced by the resident coordinator's pull/rebuild as self-authored.
    func beginCoordinatorChanges() {
        isApplyingCoordinatorChanges = true
        coordinatorObservedSlugs.removeAll()
        coordinatorBaselineBodies = Dictionary(uniqueKeysWithValues:
            ((try? skillStore.listSkills()) ?? []).map { ($0, currentOnDiskBody(directoryName: $0)) })
    }

    var coordinatorWatcherEventSequence: UInt64 {
        watcherEventSequence
    }

    func finishCoordinatorChanges(
        hasUnsyncedChanges: Bool,
        sampledWatcherEventSequence: UInt64? = nil,
        recheckHasUnsyncedChanges: () -> Bool = { false }
    ) {
        let currentSlugs = Set((try? skillStore.listSkills()) ?? [])
        let candidateSlugs = currentSlugs.union(coordinatorBaselineBodies.keys)
        var acceptedSlugs = coordinatorObservedSlugs
        var foundUnsampledChange = false
        for directoryName in candidateSlugs where !acceptedSlugs.contains(directoryName) {
            let currentBody = currentOnDiskBody(directoryName: directoryName)
            guard coordinatorBaselineBodies[directoryName] != currentBody,
                  !wasLastWrittenByApp(directoryName: directoryName, currentBody: currentBody) else { continue }
            acceptExternalChange(directoryName: directoryName, currentBody: currentBody, shouldNotify: false)
            acceptedSlugs.insert(directoryName)
            foundUnsampledChange = true
        }
        let effectiveHasUnsyncedChanges: Bool
        if let sampledWatcherEventSequence,
           sampledWatcherEventSequence != watcherEventSequence || foundUnsampledChange {
            effectiveHasUnsyncedChanges = recheckHasUnsyncedChanges()
        } else {
            effectiveHasUnsyncedChanges = hasUnsyncedChanges
        }
        for directoryName in coordinatorObservedSlugs {
            setLastWrittenBody(
                currentOnDiskBody(directoryName: directoryName), directoryName: directoryName
            )
        }
        askAboutCoordinatorChanges(acceptedSlugs)
        // The fingerprint is not observed (`lastWrittenBody`): one main-thread signal after the final re-seed
        // re-evaluates dirtiness — File › Save, the editor's clean reload — so a draft that matched a transient
        // body reads dirty again where it is shown (batch Layer-2, round 4).
        if !coordinatorObservedSlugs.isEmpty { noteEditorBodyInvalidated() }
        if !effectiveHasUnsyncedChanges {
            // A clean pull settles the mark — except on a file whose retained draft is still dirty, where
            // "Modified externally — Save overwrites it" is exactly the warning the draft needs.
            externallyModified.subtract(acceptedSlugs.filter { !hasUnsavedChanges(forDirectory: $0) })
        }
        coordinatorBaselineBodies.removeAll()
        coordinatorObservedSlugs.removeAll()
        isApplyingCoordinatorChanges = false
        if effectiveHasUnsyncedChanges, !acceptedSlugs.isEmpty { notifier() }
    }

    /// The cycle's one question, against its final body: a draft still dirty on a file the cycle moved (its
    /// body differs from the cycle's baseline) is asked about once, here, never at an intermediate event; a
    /// transient body that came and went asks nothing and keeps the draft.
    private func askAboutCoordinatorChanges(_ slugs: Set<String>) {
        for directoryName in slugs.sorted()
        where hasUnsavedChanges(forDirectory: directoryName)
            && coordinatorBaselineBodies[directoryName] != currentOnDiskBody(directoryName: directoryName) {
            requestUnsavedChangesPrompt(directoryName: directoryName, reason: .externalChange)
        }
    }

    // MARK: - File watching

    /// Register the change handler and start the watcher. Idempotent.
    /// Call from the app/ContentView lifecycle (main thread).
    func startWatching() {
        guard !isWatching else { return }
        isWatching = true
        fileWatchService.onChange = { [weak self] directoryName in
            self?.handleExternalChange(directoryName: directoryName)
        }
        fileWatchService.start()
    }

    func stopWatching() {
        guard isWatching else { return }
        isWatching = false
        fileWatchService.stop()
    }

    /// Handle an external-change notification for `directoryName`.
    /// The watcher delivers on the MAIN queue, so this runs on main — safe to mutate
    /// @Observable state directly, no extra hop. Suppress the app's OWN writes via the
    /// last-written-content fingerprint: if the on-disk body equals what we last wrote/loaded,
    /// this event is our echo, not a real external edit.
    /// An unreadable file reads as an empty body: the app's own deletion records that fingerprint
    /// (`deleteSkillEntry`, PLAN-26), so its echo — and every repeat event for one disappearance — is ours;
    /// a file that vanishes under a known body is an external change to nothing.
    private func handleExternalChange(directoryName: String) {
        watcherEventSequence &+= 1
        let currentBody = currentOnDiskBody(directoryName: directoryName)
        if wasLastWrittenByApp(directoryName: directoryName, currentBody: currentBody) {
            return
        }
        if isApplyingCoordinatorChanges {
            coordinatorObservedSlugs.insert(directoryName)
            acceptExternalChange(directoryName: directoryName, currentBody: currentBody, shouldNotify: false)
            return
        }
        acceptExternalChange(directoryName: directoryName, currentBody: currentBody, shouldNotify: true)
    }

    // MARK: - The unreadable-store fence (PLAN-31); its two writers sit with the flag

    /// Every entry point that creates a new entity — a skill by sheet, scan, folder, or GitHub; a
    /// project; a category — and the first-launch wizard read this, never
    /// `libraryUnavailable` alone. Edits read `libraryUnavailable` / `isWriteFenced` as before.
    var addsFenced: Bool { libraryUnavailable || storeUnreadable }

    /// One sentence for a refused add; the sidebar's sync card carries the longer explanation.
    static let storeUnreadableMessage =
        "Pensieve can't add to this library until it can read it. Update Pensieve, then relaunch."
}
