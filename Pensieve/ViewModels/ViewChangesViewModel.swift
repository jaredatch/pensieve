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
    private(set) var isApplying = false
    var asksToReplaceLocalEdits = false
    private(set) var applyMessage: String?

    private let operations: UpdatesViewModel
    private var identity: ViewChangesIdentity?
    private var sessionID = UUID()
    private var replacementSession: UUID?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var cancelWorker: (() -> Void)?

    init(operations: UpdatesViewModel) {
        self.operations = operations
    }

    var files: [PinnedSkillFileDiff] {
        guard case let .loaded(preview) = state else { return [] }
        return preview.files
    }

    var selectedFile: PinnedSkillFileDiff? {
        files.first { $0.path == selectedFilePath }
    }

    var canUpdate: Bool {
        guard case .loaded = state else { return false }
        return row != nil && !isPreparingUpdate && !isApplying
    }

    func selectFile(path: String) {
        guard files.contains(where: { $0.path == path }) else { return }
        selectedFilePath = path
    }

    func open(skillID: UUID, context: ModelContext, folderRevision: UInt64 = 0) {
        close()
        do {
            guard let skill = try context.fetch(FetchDescriptor<Skill>()).first(where: { $0.id == skillID }) else {
                state = .stale("This skill was deleted.")
                return
            }
            identity = ViewChangesIdentity(skill: skill, folderRevision: folderRevision)
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
        }
    }

    func retry(context: ModelContext, folderRevision: UInt64 = 0) {
        guard let identity, !isApplying else { return }
        open(skillID: identity.skillID, context: context, folderRevision: folderRevision)
    }

    func validate(skills: [Skill], folderRevisions: [String: UInt64]) {
        guard let identity, !isApplying else { return }
        let message: String?
        if let skill = skills.first(where: { $0.id == identity.skillID }) {
            if !UpdatesViewModel.isEligibleForUpdates(skill) {
                message = "This skill no longer has an update."
            } else if ViewChangesIdentity(
                skill: skill, folderRevision: folderRevisions[skill.directoryName, default: 0]
            ) != identity {
                message = "This skill changed since you opened its preview. Open View Changes again to review the current update."
            } else { message = nil }
        } else { message = "This skill was deleted." }
        guard let message else { return }
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
        row = nil
        selectedFilePath = nil
        state = .idle
        asksToReplaceLocalEdits = false
        replacementSession = nil
        isPreparingUpdate = false
        isApplying = false
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
        guard let requested = row else { return }
        let container = context.container
        let loader = operations.rowLoader
        let diff = operations.diffOperation
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let row = try loader(container).first(where: { $0.id == requested.id }) else {
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
            let (loadedRow, preview) = try await worker.value
            guard sessionID == session, !Task.isCancelled else { return }
            row = loadedRow
            selectedFilePath = preview.files.first?.path
            state = .loaded(preview)
        } catch {
            guard sessionID == session, !Task.isCancelled else { return }
            state = .failed(UpdatesViewModel.readable(error))
        }
        guard sessionID == session else { return }
        previewTask = nil
        cancelWorker = nil
    }

    func requestUpdate(library: SkillLibraryViewModel, context: ModelContext, onSuccess: @escaping () -> Void) {
        guard canUpdate, let row, let skill = try? context.fetch(FetchDescriptor<Skill>()).first(where: { $0.id == row.id }),
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
                  let skill = try? context.fetch(FetchDescriptor<Skill>()).first(where: { $0.id == row.id }),
                  !library.isWriteFenced(skill) else { return }
            self.apply(row: row, overwrite: true, library: library, context: context, onSuccess: onSuccess)
        }
    }

    private func apply(row: UpdatesRow, overwrite: Bool, library: SkillLibraryViewModel,
                       context: ModelContext, onSuccess: @escaping () -> Void) {
        isApplying = true
        applyMessage = nil
        let session = sessionID
        let applyModel = UpdatesViewModel(
            rowLoader: operations.rowLoader, applyOperation: operations.applyOperation,
            diffOperation: operations.diffOperation, recheckOperation: operations.recheckOperation,
            notifier: operations.notifier, echoRegistrar: operations.echoRegistrar,
            bodyWriteRegistration: operations.bodyWriteRegistration
        )
        applyModel.rows = [row]
        applyModel.selectedSkillIDs = [row.id]
        if overwrite { applyModel.confirmedDriftSkillIDs = [row.id] }
        // Once apply starts, closing/switching cancels only the preview. Its mutation, presentation merge
        // and notifications still finish, but its success can never close a newer window session.
        Task {
            await applyModel.applySelectedAndReport(context: context)
            let status = applyModel.status(for: row)
            if case .failedAfterReplacement = status { library.noteEditorBodyInvalidated() }
            guard self.sessionID == session else { return }
            self.isApplying = false
            switch status {
            case .updated:
                self.close()
                onSuccess()
            case .confirmationRequired:
                self.row = row.markedDrifted()
                self.applyMessage = "This skill now has local edits. Update again to confirm replacing them."
            case let .failed(message, _):
                self.applyMessage = message
            case let .failedAfterReplacement(message):
                self.retirePreview()
                self.selectedFilePath = nil
                self.state = .stale("The skill's files were replaced, but the update couldn't finish: \(message)")
            case .idle, .updating:
                break
            }
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
