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
    private(set) var isRechecking = false
    private(set) var requestedSkillID: UUID?

    private let library: SkillLibraryViewModel
    private let operations: UpdateReviewOperations
    private weak var updates: UpdatesViewModel?
    private var recheckFailureIdentity: ViewChangesIdentity?
    private var offersRecheck = false
    private let skillLookup: (UUID, ModelContext) throws -> Skill?
    private var identity: ViewChangesIdentity?
    private var sessionID = UUID()
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var cancelWorker: (() -> Void)?

    init(library: SkillLibraryViewModel, operations: UpdateReviewOperations, updates: UpdatesViewModel? = nil,
         skillLookup: @escaping (UUID, ModelContext) throws -> Skill? = UpdatesViewModel.findSkill) {
        self.library = library
        self.operations = operations
        self.updates = updates
        self.skillLookup = skillLookup
    }

    var canRecheck: Bool { offersRecheck && requestedSkillID != nil && !isRechecking }

    var files: [PinnedSkillFileDiff] {
        guard case let .loaded(preview) = state else { return [] }
        return preview.files
    }

    var selectedFile: PinnedSkillFileDiff? {
        files.first { $0.path == selectedFilePath }
    }

    var canUpdate: Bool {
        guard case .loaded = state else { return false }
        return row != nil && !isRechecking
    }

    func selectFile(path: String) {
        guard files.contains(where: { $0.path == path }) else { return }
        selectedFilePath = path
    }

    func open(skillID: UUID, context: ModelContext, folderRevision: UInt64? = nil,
              folderRevisions: [String: UInt64] = [:]) {
        do {
            if requestedSkillID == skillID, case .loaded = state,
               let skill = try skillLookup(skillID, context),
               identity == ViewChangesIdentity(skill: skill,
                   folderRevision: folderRevision ?? folderRevisions[skill.directoryName, default: 0]) {
                return
            }
            close()
            requestedSkillID = skillID
            guard let skill = try skillLookup(skillID, context) else {
                state = .stale("This skill was deleted.")
                return
            }
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
        guard let requestedSkillID, !isRechecking else { return }
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
            if let row, let origin = skill.installedOrigin,
               origin.installedCommit == row.upstreamCommit, origin.installedTree == row.upstreamTree {
                message = "This skill was updated."
            } else if !UpdatesViewModel.isEligibleForUpdates(skill) {
                message = "This skill no longer has an update."
            } else if current != identity {
                message = "This skill changed since you opened its preview. Open View Changes again to review the current update."
            } else { message = nil }
        } else { message = "This skill was deleted." }
        guard let message else { return }
        markStale(message)
    }

    private func markStale(_ message: String) {
        offersRecheck = false
        isRechecking = false
        retirePreview()
        state = .stale(message)
        selectedFilePath = nil
    }

    func close() {
        retirePreview()
        identity = nil
        requestedSkillID = nil
        offersRecheck = false
        recheckFailureIdentity = nil
        isRechecking = false
        row = nil
        selectedFilePath = nil
        state = .idle
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
        let diff = operations.diffOperation
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try diff(requested, container)
        }
        cancelWorker = { worker.cancel() }
        do {
            let preview = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            guard sessionID == session, !Task.isCancelled else { return }
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
    func recheck(context: ModelContext) {
        guard canRecheck, let requestedSkillID else { return }
        retirePreview()
        state = .loading
        isRechecking = true
        let session = sessionID
        let operation = operations.recheckOperation
        let container = context.container
        previewTask = Task {
            guard self.sessionID == session, !Task.isCancelled else { return }
            do { try await self.updates?.waitForCompletion(affecting: requestedSkillID) } catch { return }
            guard self.sessionID == session, !Task.isCancelled else { return }
            if let skill = try? self.skillLookup(requestedSkillID, context), let row = self.row,
               let origin = skill.installedOrigin, origin.installedCommit == row.upstreamCommit,
               origin.installedTree == row.upstreamTree {
                self.markStale("This skill was updated.")
                return
            }
            let worker = Task.detached(priority: .userInitiated) {
                try UpdatesViewModel.performUnlessCancelled { try operation(requestedSkillID, container) }
            }
            self.cancelWorker = { worker.cancel() }
            let result = await withTaskCancellationHandler {
                await worker.result
            } onCancel: { worker.cancel() }
            guard self.sessionID == session, !Task.isCancelled else { return }
            let failure: String?
            switch result {
            case let .success(completion):
                UpdatesViewModel.applyRecheckCompletion(completion, context: context)
                failure = completion.checkError
            case let .failure(error): failure = UpdatesViewModel.readable(error)
            }
            if failure == nil {
                self.open(skillID: requestedSkillID, context: context, folderRevisions: self.library.folderChangeRevisions)
            } else {
                // The check's own metadata write must not replace its error with an ineligibility message.
                if let skill = try? self.skillLookup(requestedSkillID, context), skill.modelContext != nil {
                    self.recheckFailureIdentity = ViewChangesIdentity(
                        skill: skill, folderRevision: self.library.folderChangeRevisions[skill.directoryName, default: 0]
                    )
                }
                self.isRechecking = false
                self.state = .failed(failure ?? "The check failed.")
                self.offersRecheck = true
                self.previewTask = nil
                self.cancelWorker = nil
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
