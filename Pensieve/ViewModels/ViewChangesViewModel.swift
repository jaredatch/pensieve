import Foundation
import Observation
import SwiftData

/// Preview lifetime belongs to the auxiliary window, independently of the Updates sheet.
@MainActor
@Observable
final class ViewChangesViewModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded(PinnedSkillDiff)
        case failed(String)
        case stale(String)
    }

    private(set) var state: State = .idle
    private(set) var row: UpdatesRow?
    private(set) var selectedFilePath: String?
    private(set) var isPreparingUpdate = false
    private(set) var isRechecking = false
    private(set) var requestedSkillID: UUID?
    var isApplying: Bool { requestedSkillID.map { applyGate.isApplying($0) } ?? false }
    var asksToReplaceLocalEdits = false
    private(set) var applyMessage: String?

    private let library: SkillLibraryViewModel
    private var presentationContext: ModelContext?
    private let operations: UpdateReviewOperations
    private let applyCoordinator: SkillUpdateApplyCoordinator
    private var applyGate: SkillUpdateApplyGate { applyCoordinator.gate }
    private var currentSkill: Skill?
    private var deferredValidationMessage: String?
    private var recheckFailureIdentity: ViewChangesIdentity?
    private var offersRecheck = false
    private let skillLookup: (UUID, ModelContext) throws -> Skill?
    private var identity: ViewChangesIdentity?
    private var sessionID = UUID()
    private var replacementSession: UUID?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var cancelWorker: (() -> Void)?

    init(library: SkillLibraryViewModel, operations: UpdateReviewOperations, applyCoordinator: SkillUpdateApplyCoordinator? = nil,
         skillLookup: @escaping (UUID, ModelContext) throws -> Skill? = UpdatesViewModel.findSkill) {
        self.library = library
        self.operations = operations
        self.applyCoordinator = applyCoordinator ?? SkillUpdateApplyCoordinator()
        self.skillLookup = skillLookup
        self.applyCoordinator.observe(self)
    }

    var canRecheck: Bool { offersRecheck && requestedSkillID != nil && !isApplying && !isRechecking }

    var files: [PinnedSkillFileDiff] {
        guard case let .loaded(preview) = state else { return [] }
        return preview.files
    }

    var selectedFile: PinnedSkillFileDiff? {
        files.first { $0.path == selectedFilePath }
    }

    var canUpdate: Bool {
        guard case .loaded = state else { return false }
        return row != nil && !isPreparingUpdate && !isApplying && !isRechecking
    }

    func selectFile(path: String) {
        guard files.contains(where: { $0.path == path }) else { return }
        selectedFilePath = path
    }

    func moveFileSelection(_ delta: Int) {
        guard let selectedFilePath, let index = files.firstIndex(where: { $0.path == selectedFilePath }),
              files.indices.contains(index + delta) else { return }
        selectFile(path: files[index + delta].path)
    }

    func open(skillID: UUID, context: ModelContext, folderRevision: UInt64? = nil,
              folderRevisions: [String: UInt64] = [:]) {
        close()
        requestedSkillID = skillID
        presentationContext = context
        do {
            guard let skill = try skillLookup(skillID, context) else {
                state = .stale("This skill was deleted.")
                return
            }
            currentSkill = skill
            identity = ViewChangesIdentity(skill: skill,
                                           folderRevision: folderRevision ?? folderRevisions[skill.directoryName, default: 0])
            guard UpdatesViewModel.isEligibleForUpdates(skill) else {
                state = .stale("This skill no longer has an update.")
                return
            }
            row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
            state = .loading
            let session = sessionID
            previewTask = Task { await loadPreview(context: context, session: session) }
        } catch {
            state = .failed(UpdatesViewModel.readable(error))
            offersRecheck = UpdatesViewModel.offersRecheck(error)
        }
    }

    func retry(context: ModelContext, folderRevision: UInt64? = nil, folderRevisions: [String: UInt64] = [:]) {
        guard let requestedSkillID, !isApplying, !isRechecking else { return }
        open(skillID: requestedSkillID, context: context, folderRevision: folderRevision, folderRevisions: folderRevisions)
    }

    func validate(skills: [Skill], folderRevisions: [String: UInt64], context: ModelContext) {
        guard let identity else { return }
        let skill: Skill?
        do {
            // A filtered Query can still contain the prior skill while SwiftUI switches its filter.
            skill = try skills.first(where: { $0.modelContext != nil && !$0.isDeleted && $0.id == identity.skillID })
                ?? skillLookup(identity.skillID, context)
        } catch {
            markStale("Couldn't verify whether this preview is current: " + UpdatesViewModel.readable(error))
            return
        }
        let message: String?
        if let skill, skill.modelContext != nil, !skill.isDeleted {
            // A retired preview keeps its failure reason until reopened; deletion still takes precedence below.
            if case .stale = state { return }
            let current = ViewChangesIdentity(skill: skill, folderRevision: folderRevisions[skill.directoryName, default: 0])
            if current == recheckFailureIdentity { return }
            if !UpdatesViewModel.isEligibleForUpdates(skill) {
                message = "This skill no longer has an update."
            } else if current != identity {
                message = "This skill changed since you opened its preview. Open View Changes again to review the current update."
            } else { message = nil }
        } else { message = "This skill was deleted." }
        deferredValidationMessage = message
        guard !isApplying, let message else { return }
        markStale(message)
    }

    private func markStale(_ message: String) {
        offersRecheck = false
        isRechecking = false
        retirePreview()
        state = .stale(message)
        selectedFilePath = nil
        asksToReplaceLocalEdits = false
        replacementSession = nil
        isPreparingUpdate = false
        applyMessage = nil
    }

    func close() {
        retirePreview()
        identity = nil
        requestedSkillID = nil
        presentationContext = nil
        currentSkill = nil
        deferredValidationMessage = nil
        offersRecheck = false
        recheckFailureIdentity = nil
        isRechecking = false
        row = nil
        selectedFilePath = nil
        state = .idle
        asksToReplaceLocalEdits = false
        replacementSession = nil
        isPreparingUpdate = false
        applyMessage = nil
    }

    private func retirePreview() {
        sessionID = UUID()
        previewTask?.cancel()
        cancelWorker?()
        previewTask = nil
        cancelWorker = nil
    }

    private func loadPreview(context: ModelContext, session: UUID) async {
        guard sessionID == session, !Task.isCancelled, let requested = row else { return }
        let container = context.container
        let loader = operations.previewRowLoader
        let diff = operations.diffOperation
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let row = try loader(requested.id, container) else {
                throw SkillUpdateFlowError.missingPinnedUpdate
            }
            guard row.installedCommit == requested.installedCommit,
                  row.upstreamCommit == requested.upstreamCommit, row.upstreamTree == requested.upstreamTree else {
                throw SkillUpdateFlowError.repositoryChanged
            }
            try Task.checkCancellation()
            return (row, try diff(row.id, row.upstreamCommit, row.upstreamTree, container))
        }
        cancelWorker = { worker.cancel() }
        do {
            let (loadedRow, preview) = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            guard sessionID == session, !Task.isCancelled else { return }
            row = loadedRow
            selectedFilePath = preview.files.first?.path
            state = .loaded(preview)
        } catch {
            guard sessionID == session, !Task.isCancelled else { return }
            state = .failed(UpdatesViewModel.readable(error))
            offersRecheck = UpdatesViewModel.offersRecheck(error)
        }
        guard sessionID == session else { return }
        previewTask = nil
        cancelWorker = nil
    }

}

extension ViewChangesViewModel {
    func requestUpdate(library: SkillLibraryViewModel, context: ModelContext, onSuccess: @escaping () -> Void) {
        guard canUpdate, let row, let skill = currentSkill,
              !library.isWriteFenced(skill) else { return }
        isPreparingUpdate = true
        let session = sessionID
        library.confirmLeavingAnyDraft { [weak self] proceed in
            guard let self, self.sessionID == session else { return }
            self.isPreparingUpdate = false
            guard proceed, self.canUpdate, !library.isWriteFenced(skill) else { return }
            if row.driftedLocally {
                self.replacementSession = session
                self.asksToReplaceLocalEdits = true
            } else {
                self.apply(row: row, overwrite: false, library: library, context: context, onSuccess: onSuccess)
            }
        }
    }

    func confirmReplacement(_ replace: Bool, library: SkillLibraryViewModel,
                            context: ModelContext, onSuccess: @escaping () -> Void) {
        guard replacementSession == sessionID else { return }
        asksToReplaceLocalEdits = false
        replacementSession = nil
        guard replace, canUpdate, let row else { return }
        // The draft or write fence may have changed while the replacement question was open.
        isPreparingUpdate = true
        let session = sessionID
        library.confirmLeavingAnyDraft { [weak self] proceed in
            guard let self, self.sessionID == session else { return }
            self.isPreparingUpdate = false
            guard proceed, self.canUpdate,
                  let skill = currentSkill,
                  !library.isWriteFenced(skill) else { return }
            self.apply(row: row, overwrite: true, library: library, context: context, onSuccess: onSuccess)
        }
    }

    private func apply(row: UpdatesRow, overwrite: Bool, library: SkillLibraryViewModel,
                       context: ModelContext, onSuccess: @escaping () -> Void) {
        guard applyCoordinator.begin(row.id) else { return }
        applyMessage = nil
        offersRecheck = false
        let session = sessionID
        let operations = operations
        let container = context.container
        let worker = Task.detached(priority: .userInitiated) {
            try UpdatesViewModel.performUnlessCancelled {
                try operations.applyOperation(row.id, row.upstreamCommit, row.upstreamTree, overwrite,
                                              operations.bodyWriteRegistration, container)
            }
        }
        // Apply is process work: closing or switching retires only preview work, never this reservation.
        Task {
            let status = UpdateReviewResult.apply(await worker.result).resolve(
                row: row, context: context, effects: UpdateReviewEffects(
                    echo: operations.echoRegistrar, notify: operations.notifier,
                    invalidateEditorBody: { library.noteEditorBodyInvalidated() }
                )
            )
            if self.sessionID == session { self.acceptApply(status, row: row, onSuccess: onSuccess) }
            self.applyCoordinator.finish(row: row, status: status, context: context)
        }
    }

    private func acceptApply(_ status: UpdatesRowStatus, row: UpdatesRow, onSuccess: () -> Void) {
        switch status {
        case .updated:
            close()
            onSuccess()
        case .confirmationRequired:
            self.row = row.markedDrifted()
            applyMessage = "This skill now has local edits. Update again to confirm replacing them."
        case let .failed(message, recheck):
            applyMessage = message
            offersRecheck = recheck
        case let .failedAfterReplacement(message):
            markStale("The skill's files were replaced, but the update couldn't finish: \(message)")
        case .idle, .updating:
            break
        }
    }

    func recheck(context: ModelContext, library: SkillLibraryViewModel) {
        guard canRecheck, let requestedSkillID else { return }
        retirePreview()
        state = .loading
        isRechecking = true
        applyMessage = nil
        let session = sessionID
        let operation = operations.recheckOperation
        let container = context.container
        previewTask = Task {
            guard self.sessionID == session, !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                try UpdatesViewModel.performUnlessCancelled { try operation(requestedSkillID, container) }
            }
            self.cancelWorker = { worker.cancel() }
            let result = await withTaskCancellationHandler {
                await worker.result
            } onCancel: { worker.cancel() }
            guard self.sessionID == session, !Task.isCancelled else { return }
            let status = UpdateReviewResult.recheck(result).resolve(
                row: row, context: context, effects: UpdateReviewEffects(
                    echo: self.operations.echoRegistrar, notify: self.operations.notifier,
                    invalidateEditorBody: { library.noteEditorBodyInvalidated() }
                )
            )
            if case .idle = status {
                self.open(skillID: requestedSkillID, context: context, folderRevisions: library.folderChangeRevisions)
            } else {
                // The check's own metadata write must not replace its error with an ineligibility message.
                if let skill = try? self.skillLookup(requestedSkillID, context), skill.modelContext != nil {
                    self.recheckFailureIdentity = ViewChangesIdentity(
                        skill: skill, folderRevision: library.folderChangeRevisions[skill.directoryName, default: 0]
                    )
                }
                self.isRechecking = false
                self.acceptRecheckFailure(status)
                self.previewTask = nil
                self.cancelWorker = nil
            }
        }
    }

    private func acceptRecheckFailure(_ status: UpdatesRowStatus) {
        switch status {
        case let .failed(message, recheck):
            state = .failed(message)
            offersRecheck = recheck
        case .confirmationRequired:
            state = .failed("Local edits require confirmation before updating.")
            offersRecheck = true
        case let .failedAfterReplacement(message):
            markStale("The skill's files were replaced, but the check couldn't finish: " + message)
        case .idle, .updating, .updated: break
        }
    }

}

extension ViewChangesViewModel: SkillUpdateApplyObserving {
    func applyFinished(row: UpdatesRow, status: UpdatesRowStatus?, context: ModelContext) {
        guard row.id == requestedSkillID, let context = presentationContext, !isApplying, case .loaded = state else { return }
        if let deferredValidationMessage {
            markStale(deferredValidationMessage)
        } else {
            // Fetch before touching any property of a retained model that an apply may have deleted.
            validate(skills: [], folderRevisions: library.folderChangeRevisions, context: context)
        }
    }
}

struct ViewChangesIdentity: Equatable {
    let skillID: UUID
    let originData: Data?
    let upstreamCommit: String?
    let upstreamTree: String?
    let updateAvailable: Bool
    let checkError: String?
    let updatedAt: Date
    let folderRevision: UInt64

    init(skill: Skill, folderRevision: UInt64) {
        skillID = skill.id
        originData = skill.installedOriginData
        upstreamCommit = skill.upstreamCommit
        upstreamTree = skill.upstreamTree
        updateAvailable = skill.updateAvailable
        checkError = skill.checkError
        updatedAt = skill.updatedAt
        self.folderRevision = folderRevision
    }
}
