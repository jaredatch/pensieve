import Foundation

/// An unsaved edit: the skill it belongs to and the editor's whole text. An entry enters
/// `SkillLibraryViewModel.drafts` when the text differs from the file's last known document (the self-write
/// fingerprint) and leaves on Save, Revert, the skill's deletion, or the user typing back to that body;
/// Its baseline advances to the disk text when an external-change question is shown.
/// Whether it is dirty NOW is measured against the fingerprint (`hasUnsavedChanges(forDirectory:)`), never
/// remembered — a file that moves under the draft and back never costs it.
struct EditorDraft: Equatable {
    let skill: Skill
    var body: String
    var baseline: String?
}

/// The user's answer to the stock unsaved-changes sheet.
enum UnsavedChangesChoice: Equatable {
    case save
    case discard
    case cancel
}

/// Why the sheet is up. The copy is the stock sheet's either way; the reason is what a test asserts and
/// what decides the outcome — leaving carries a continuation, an external change does not.
enum UnsavedChangesReason: Equatable {
    case leaving
    case externalChange
}

/// One question outstanding. The view model owns it so the invariant holds whether or not an editor is
/// mounted (PLAN-02 / 02.3: a side effect hung on a view never runs while that view is off screen).
struct UnsavedChangesPrompt: Equatable, Identifiable {
    let id: UUID
    let directoryName: String
    let fileName: String
    let reason: UnsavedChangesReason
}

/// A question survives coordinator cycles and other sheets. Explicit Saves retry if the conflict disappears.
struct ExternalChangeQuestion {
    var saveIfUnchanged = false
    var continuation: ((Bool) -> Void)?
}

extension SkillLibraryViewModel {
    /// True while any skill has a draft that differs from its file.
    var hasUnsavedChanges: Bool { drafts.keys.contains { hasUnsavedChanges(forDirectory: $0) } }

    /// The slug of the first dirty draft by name. Two can be dirty at once — an entry kept clean by a file that
    /// caught up, made dirty again by a later external change while another skill was being edited — so the
    /// global ways out ask about each in turn (`confirmLeavingAnyDraft`) and ⌘S saves each (`saveUnsavedDrafts`).
    var unsavedDirectoryName: String? { drafts.keys.sorted().first { hasUnsavedChanges(forDirectory: $0) } }

    func hasUnsavedChanges(for skill: Skill) -> Bool { hasUnsavedChanges(forDirectory: skill.directoryName) }

    /// Dirty is measured, never remembered: the draft's text against the fingerprint as it stands now. A file
    /// that catches up with the draft (the same text arriving from outside, a remount that re-seeds, a sync
    /// cycle's final body) reads clean without anyone dropping the draft, and a file that moves away again
    /// reads dirty again with the text intact — a transient body during a sync cycle never costs the draft.
    func hasUnsavedChanges(forDirectory directoryName: String) -> Bool {
        guard let draft = drafts[directoryName] else { return false }
        // Compare the complete editor text and stored document in the same LF form as watcher echoes.
        return !Self.bodiesMatch(draft.body, withFingerprintLock { lastWrittenBody[directoryName] })
    }

    /// The text the editor shows for `skill`: its draft when one exists, else the file. The fingerprint ends
    /// re-seeded to the file, so a watcher echo of the app's last write still reads as ours and a draft is
    /// measured against what the file holds now (a draft the file has caught up with reads clean; it is not
    /// dropped — the file may be mid-cycle). A body that differs from the last known one and is not the app's
    /// own write landed while no editor was mounted: it goes through the external-change policy here — the
    /// mark, the question if the draft is dirty, the cycle's bookkeeping — so the watcher's later event, an
    /// echo of a body the fingerprint already holds, cannot swallow it.
    func editorBody(for skill: Skill) -> String {
        let directoryName = skill.directoryName
        let onDisk = readSkillDocument(skill) ?? ""
        StoreRebuildService.refreshIdentity(of: skill, document: onDisk, retainingBOM: true)
        let known = withFingerprintLock { lastWrittenBody[directoryName] }
        if let known, !Self.bodiesMatch(onDisk, known), !wasLastWrittenByApp(directoryName: directoryName, currentBody: onDisk) {
            observeExternalDocument(directoryName: directoryName, document: onDisk)
        } else {
            setLastWrittenBody(onDisk, directoryName: directoryName)
        }
        return drafts[directoryName]?.body ?? onDisk
    }

    /// A keystroke: the editor's whole text. Typing back to the file's text drops the draft — the user's own
    /// return to the file, so a later external change asks about nothing — and writes nothing.
    func noteEditorChanged(_ skill: Skill, body: String) {
        textEditRevisions[skill.directoryName, default: 0] &+= 1
        let directoryName = skill.directoryName
        let baseline = withFingerprintLock { lastWrittenBody[directoryName] }
        // Compare the complete editor text and stored document in the same LF form as watcher echoes.
        if Self.bodiesMatch(body, baseline) {
            drafts[directoryName] = nil
        } else {
            drafts[directoryName] = EditorDraft(skill: skill, body: body, baseline: drafts[directoryName]?.baseline ?? baseline)
        }
    }

    /// Check and write the complete draft once: the fingerprint moves to what was written, the
    /// external-change mark clears (the write is the newer version now), sync is nudged. A refused write
    /// (`updateDocument` sets `error`) keeps the draft, so Save is a real retry. True when nothing remains to
    /// save — including when there was no draft, or one the file has caught up with.
    ///
    /// Save edits the file it loaded and never re-creates one that is gone: a row whose deletion was saved
    /// reads `isDeleted == false` again (SwiftData resets it — `updateMetadata`'s note), and the rebuild drops
    /// orphan rows without passing `deleteSkillEntry`, so the file's presence is the check (PLAN-26: a write
    /// re-creates parents, and a skill deleted elsewhere must not come back on its own). The draft stays. The
    /// presence check comes before the cleanliness check: a draft the file has caught up with reads clean, but
    /// a draft whose file is gone must not report "nothing to save" — an empty draft over a vanished file reads
    /// clean by measure and still refuses here.
    @discardableResult
    func saveDraft(_ skill: Skill) -> Bool { performSave(skill) == .saved }

    private enum SaveOutcome { case saved, failed, awaitingAnswer }

    private func performSave(_ skill: Skill, continuation: ((Bool) -> Void)? = nil) -> SaveOutcome {
        guard let draft = drafts[skill.directoryName] else { return .saved }
        guard !skill.isDeleted, hasReadableSkillFile(skill.directoryName) else {
            error = "Failed to save: this skill's file can't be read (removed, or unreadable). "
                + "Copy the text if you need it; Don't Save discards it."
            return .failed
        }
        if pendingUnsavedChanges?.directoryName == skill.directoryName,
           pendingUnsavedChanges?.reason == .externalChange {
            if let continuation { pendingLeaveContinuation = continuation }
            return .awaitingAnswer
        }
        guard hasUnsavedChanges(forDirectory: skill.directoryName) else { return .saved }
        let onDisk = currentOnDiskBody(directoryName: skill.directoryName)
        if !Self.bodiesMatch(onDisk, draft.baseline), !Self.bodiesMatch(onDisk, draft.body) {
            queueExternalQuestion(directoryName: skill.directoryName, saveIfUnchanged: true, continuation: continuation)
            observeExternalDocument(directoryName: skill.directoryName, document: onDisk)
            drainExternalQuestions()
            return .awaitingAnswer
        }
        let outcome = updateDocument(skill, document: draft.body, original: onDisk)
        guard outcome.succeeded else { return .failed }
        drafts[skill.directoryName] = nil
        externallyModified.remove(skill.directoryName)
        if outcome == .written { notifier() }
        return .saved
    }

    /// File › Save (⌘S): every dirty draft, first by name — true when none remains, false at the first refused
    /// write (its error set, the rest untouched).
    @discardableResult
    func saveUnsavedDrafts() -> Bool {
        for directoryName in drafts.keys.sorted() where hasUnsavedChanges(forDirectory: directoryName) {
            guard let draft = drafts[directoryName], saveDraft(draft.skill) else { return false }
        }
        return true
    }

    /// Revert: drop the draft and ask a mounted editor to reload the file (the token is the editor's
    /// reload signal; a clean editor reloads on it, a dirty one never does). Nothing is written.
    func discardDraft(_ skill: Skill) {
        guard drafts.removeValue(forKey: skill.directoryName) != nil else { return }
        noteEditorBodyInvalidated()
    }

    /// The gate every way out passes. Clean: `then(true)` at once, no sheet. Dirty: the sheet, and `then`
    /// runs with the answer — Save → true after a successful write and false after a refused one; Don't
    /// Save → true; Cancel → false. A second question while one is open is refused (`then(false)`): the
    /// sheet is modal to the window, so this is a programmatic race, never a user's.
    func confirmLeaving(_ skill: Skill, then: @escaping (Bool) -> Void) {
        guard hasUnsavedChanges(for: skill) else { then(true); return }
        guard pendingUnsavedChanges == nil else { then(false); return }
        pendingLeaveContinuation = then
        present(directoryName: skill.directoryName, reason: .leaving)
    }

    /// The gate for leaving several skills at once (a multi-selection moving on, a row deleted while others
    /// were selected): the whole departing set is kept, answered skills included, and its dirty members are
    /// re-read after every answer — each dirty one asked about in turn, first by name, one that turned dirty
    /// during another's question (its own question refused while one was open) included, even one already
    /// answered Save while its file had caught up (a no-op save keeps the entry) whose file moved on again;
    /// the way out proceeds only once none is dirty. One Cancel stops it; so does a refused save.
    func confirmLeaving(_ skills: [Skill], then: @escaping (Bool) -> Void) {
        let all = skills.sorted { $0.directoryName < $1.directoryName }
        guard let skill = all.first(where: { hasUnsavedChanges(for: $0) }) else { then(true); return }
        confirmLeaving(skill) { [weak self] proceed in
            guard proceed, let self else { then(proceed); return }
            self.confirmLeaving(all, then: then)
        }
    }

    /// The gate for a way out that is not about one skill — quit, the window's close, the Skill Updates
    /// sheet: every dirty draft is asked about in turn, first by name, and the way out proceeds only once each
    /// was saved or discarded; one Cancel stops it. A draft that turns dirty while a question is open (an
    /// external change refused a second question) is reached by the same loop.
    func confirmLeavingAnyDraft(then: @escaping (Bool) -> Void) {
        guard let directoryName = unsavedDirectoryName, let draft = drafts[directoryName] else {
            // Nothing dirty: a user-driven way out — quit, the window's close, Skill Updates — settles the entries
            // the file has caught up with, outside a sync cycle (a transient body must not cost a draft). An
            // app-authored write that follows (an update's) would otherwise turn a stale entry dirty under itself
            // and win the next Save (batch Layer-2).
            if !isApplyingCoordinatorChanges { drafts.removeAll() }
            then(true); return
        }
        confirmLeaving(draft.skill) { [weak self] proceed in
            guard proceed, let self else { then(proceed); return }
            self.confirmLeavingAnyDraft(then: then)
        }
    }

    /// Queue by file, not by cycle. A second sheet or repeated Save cannot consume an unanswered question.
    func requestUnsavedChangesPrompt(directoryName: String, reason: UnsavedChangesReason) {
        queueExternalQuestion(directoryName: directoryName)
        drainExternalQuestions()
    }

    private func queueExternalQuestion(directoryName: String, saveIfUnchanged: Bool = false,
                                       continuation: ((Bool) -> Void)? = nil) {
        if pendingUnsavedChanges?.directoryName == directoryName, pendingUnsavedChanges?.reason == .externalChange,
           Self.bodiesMatch(currentOnDiskBody(directoryName: directoryName), drafts[directoryName]?.baseline) {
            if let continuation { pendingLeaveContinuation = continuation }
            return
        }
        var question = externalChangeQuestions[directoryName] ?? ExternalChangeQuestion()
        question.saveIfUnchanged = question.saveIfUnchanged || saveIfUnchanged
        question.continuation = continuation ?? question.continuation
        externalChangeQuestions[directoryName] = question
    }

    /// Re-read at presentation: Cancel acknowledges exactly this text; a later change needs another answer.
    func drainExternalQuestions() {
        guard !isApplyingCoordinatorChanges, !isDrainingExternalQuestions else { return }
        isDrainingExternalQuestions = true
        defer { isDrainingExternalQuestions = false }
        while pendingUnsavedChanges == nil, let slug = externalChangeQuestions.keys.sorted().first {
            guard let question = externalChangeQuestions.removeValue(forKey: slug) else { continue }
            guard let draft = drafts[slug] else { question.continuation?(true); continue }
            let onDisk = currentOnDiskBody(directoryName: slug)
            observeExternalDocument(directoryName: slug, document: onDisk)
            externalChangeQuestions[slug] = nil
            if Self.bodiesMatch(onDisk, draft.baseline) || !hasUnsavedChanges(forDirectory: slug) {
                externallyModified.remove(slug)
                if question.saveIfUnchanged {
                    let outcome = performSave(draft.skill, continuation: question.continuation)
                    if outcome != .awaitingAnswer { question.continuation?(outcome == .saved) }
                }
                continue
            }
            drafts[slug]?.baseline = onDisk
            pendingLeaveContinuation = question.continuation
            present(directoryName: slug, reason: .externalChange)
        }
    }

    func resolveUnsavedChanges(_ choice: UnsavedChangesChoice) {
        guard let prompt = pendingUnsavedChanges else { return }
        let continuation = pendingLeaveContinuation
        pendingUnsavedChanges = nil
        pendingLeaveContinuation = nil
        let skill = drafts[prompt.directoryName]?.skill
        switch choice {
        case .save:
            let outcome = skill.map { performSave($0, continuation: continuation) } ?? .saved
            if outcome != .awaitingAnswer { continuation?(outcome == .saved) }
        case .discard:
            if let skill { discardDraft(skill) }
            continuation?(true)
        case .cancel:
            continuation?(false)
        }
        drainExternalQuestions()
    }

    private func present(directoryName: String, reason: UnsavedChangesReason) {
        let prompt = UnsavedChangesPrompt(
            id: UUID(), directoryName: directoryName, fileName: "\(directoryName)/SKILL.md", reason: reason
        )
        pendingUnsavedChanges = prompt
        unsavedChangesPresenter(prompt) { [weak self] choice in self?.resolveUnsavedChanges(choice) }
    }
}
