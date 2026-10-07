import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class UpdatesViewModel {
    typealias RowLoader = (ModelContainer) throws -> [UpdatesRow]
    typealias ApplyOperation = (
        UUID, String, String, Bool, SyncBodyWriteRegistration, ModelContainer
    ) throws -> SkillUpdateCompletion
    typealias RecheckOperation = (UUID, ModelContainer) throws -> SkillUpdateRecheckCompletion

    var rows: [UpdatesRow] = []
    var selectedSkillIDs: Set<UUID> = []
    var confirmedDriftSkillIDs: Set<UUID> = []
    var statuses: [UUID: UpdatesRowStatus] = [:]
    var loadPhase: UpdatesLoadPhase = .idle
    var isLoading: Bool { loadPhase == .loading }
    var isApplying = false
    var recheckingSkillID: UUID?
    var isPresented = false
    var initialSelection: Set<UUID>?

    let rowLoader: RowLoader
    let applyOperation: ApplyOperation
    let recheckOperation: RecheckOperation
    var operationID: UUID?
    var operationTask: Task<Void, Never>?
    var backgroundCancel: (() -> Void)?
    let notifier: SyncStateNotifying
    let echoRegistrar: SyncWriteEchoRegistering
    let bodyWriteRegistration: SyncBodyWriteRegistration
    weak var viewChanges: ViewChangesViewModel?
    @ObservationIgnored weak var editorLibrary: SkillLibraryViewModel?

    init(
        rowLoader: @escaping RowLoader,
        applyOperation: @escaping ApplyOperation,
        recheckOperation: @escaping RecheckOperation,
        notifier: @escaping SyncStateNotifying = SyncStateNotifier.suppressed,
        echoRegistrar: @escaping SyncWriteEchoRegistering = SyncWriteEchoRegistrar.suppressed,
        bodyWriteRegistration: SyncBodyWriteRegistration = .suppressed
    ) {
        self.rowLoader = rowLoader
        self.applyOperation = applyOperation
        self.recheckOperation = recheckOperation
        self.notifier = notifier
        self.echoRegistrar = echoRegistrar
        self.bodyWriteRegistration = bodyWriteRegistration
    }

    /// Admission for another surface: the sheet owns the meaning of its active work.
    func isBusy(affecting skillID: UUID) -> Bool {
        recheckingSkillID == skillID
            || (isApplying && (statuses[skillID] == .updating || selectableRows.contains {
                $0.id == skillID && isSelected($0) && (!$0.driftedLocally || confirmedDriftSkillIDs.contains($0.id))
            }))
    }

    var selectableSkillIDs: Set<UUID> {
        let currentStatuses = statuses
        return Set(rows.lazy.filter { currentStatuses[$0.id] != .updated }.map(\.id))
    }
    var selectableRows: [UpdatesRow] {
        let ids = selectableSkillIDs
        return rows.filter { ids.contains($0.id) }
    }
    var selectedCount: Int { selectedSkillIDs.intersection(selectableSkillIDs).count }
    var canApply: Bool {
        let selection = selectedSkillIDs.intersection(selectableSkillIDs)
        return loadPhase == .loaded && !isApplying && recheckingSkillID == nil && !selection.isEmpty
            && selection.allSatisfy { viewChanges?.isBusy(affecting: $0) != true }
    }

    func canRecheck(_ row: UpdatesRow) -> Bool {
        !isApplying && recheckingSkillID == nil && viewChanges?.isBusy(affecting: row.id) != true
    }

    private var canLoad: Bool {
        guard !isApplying else { return false }
        switch loadPhase {
        case .idle, .failed: return true
        case .loading, .loaded: return false
        }
    }

    func isSelectable(_ row: UpdatesRow) -> Bool {
        selectableSkillIDs.contains(row.id)
    }

    func isSelected(_ row: UpdatesRow) -> Bool {
        selectedSkillIDs.contains(row.id)
    }

    func setSelection(_ selected: Bool, for row: UpdatesRow) {
        guard !isApplying, isSelectable(row) else { return }
        if selected { selectedSkillIDs.insert(row.id) } else { selectedSkillIDs.remove(row.id) }
    }

    func setDriftConfirmation(_ confirmed: Bool, for row: UpdatesRow) {
        guard row.driftedLocally, !isApplying, isSelectable(row) else { return }
        if confirmed {
            confirmedDriftSkillIDs.insert(row.id)
            selectedSkillIDs.insert(row.id)
            statuses[row.id] = .idle
        } else {
            confirmedDriftSkillIDs.remove(row.id)
        }
    }

    func status(for row: UpdatesRow) -> UpdatesRowStatus {
        statuses[row.id] ?? .idle
    }

    func load(context: ModelContext) {
        guard canLoad else { return }
        let id = beginOperation()
        loadPhase = .loading
        let container = context.container
        operationTask = Task { await performLoad(container: container, operationID: id) }
    }

    func loadAndReport(context: ModelContext) async {
        guard canLoad else { return }
        let id = beginOperation()
        loadPhase = .loading
        await performLoad(container: context.container, operationID: id)
    }

    func applySelected(context: ModelContext) {
        guard canApply else { return }
        let id = beginOperation()
        isApplying = true
        let selected = selectableRows.filter(isSelected)
        let container = context.container
        operationTask = Task {
            await performApply(
                rows: selected,
                container: container,
                presentationContext: context,
                operationID: id
            )
        }
    }

    func applySelectedAndReport(context: ModelContext) async {
        guard canApply else { return }
        let id = beginOperation()
        isApplying = true
        let selected = selectableRows.filter(isSelected)
        await performApply(
            rows: selected,
            container: context.container,
            presentationContext: context,
            operationID: id
        )
    }

    func recheck(_ row: UpdatesRow, context: ModelContext) {
        guard canRecheck(row) else { return }
        let id = beginOperation()
        statuses[row.id] = .updating
        recheckingSkillID = row.id
        let container = context.container
        operationTask = Task {
            await performRecheck(
                row: row,
                container: container,
                presentationContext: context,
                operationID: id
            )
        }
    }

    func recheckAndReport(_ row: UpdatesRow, context: ModelContext) async {
        guard canRecheck(row) else { return }
        let id = beginOperation()
        statuses[row.id] = .updating
        recheckingSkillID = row.id
        await performRecheck(
            row: row,
            container: context.container,
            presentationContext: context,
            operationID: id
        )
    }

    func present(selecting skillID: UUID? = nil, library: SkillLibraryViewModel) {
        guard !library.libraryUnavailable else { return }
        if isPresented {
            guard !isApplying, loadPhase == .loaded, let skillID,
                  selectableSkillIDs.contains(skillID) else { return }
            selectedSkillIDs.insert(skillID)
            return
        }
        library.confirmLeavingAnyDraft { [weak self] proceed in
            guard let self, proceed else { return }
            self.reset()
            self.editorLibrary = library
            self.initialSelection = skillID.map { [$0] }
            self.isPresented = true
        }
    }

    func reset() {
        cancel()
        rows = []
        loadPhase = .idle
        selectedSkillIDs = []
        confirmedDriftSkillIDs = []
        statuses = [:]
        initialSelection = nil
        isPresented = false
    }

    func cancel() {
        operationID = nil
        operationTask?.cancel()
        backgroundCancel?()
        operationTask = nil
        backgroundCancel = nil
        if isLoading { loadPhase = .idle }
        isApplying = false
        recheckingSkillID = nil
    }

    nonisolated static func noticeCount(in skills: [Skill]) -> Int {
        skills.filter(isEligibleForUpdates).count
    }

    /// The banner's copy for `noticeCount(in:)`.
    nonisolated static func noticeText(count: Int) -> String {
        count == 1 ? "1 skill update available" : "\(count) skill updates available"
    }

    nonisolated static func isEligibleForUpdates(_ skill: Skill) -> Bool {
        skill.hasLinkedOrigin && skill.updateAvailable && skill.checkError == nil
    }
}
