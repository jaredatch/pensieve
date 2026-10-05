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
    typealias DiffOperation = (UUID, String, String, ModelContainer) throws -> PinnedSkillDiff
    typealias RecheckOperation = (UUID, ModelContainer) throws -> SkillUpdateRecheckCompletion

    var rows: [UpdatesRow] = [] {
        didSet {
            rowIDs = Set(rows.map(\.id))
            applyReservationsChanged()
        }
    }
    var rowIDs: Set<UUID> = []
    var hasReservedRows = false
    var invalidateEditorBody: () -> Void = {}
    var currentFolderRevisions: () -> [String: UInt64] = { [:] }
    var selectedSkillIDs: Set<UUID> = []
    var confirmedDriftSkillIDs: Set<UUID> = []
    var statuses: [UUID: UpdatesRowStatus] = [:]
    var isLoading = false
    var isApplyingBatch = false
    let applyCoordinator: SkillUpdateApplyCoordinator
    var applyGate: SkillUpdateApplyGate { applyCoordinator.gate }
    var isApplying: Bool { isApplyingBatch || hasReservedRows }
    var recheckingSkillID: UUID?
    var loadError: String?
    var isPresented = false
    var initialSelection: Set<UUID>?

    let rowLoader: RowLoader
    let applyOperation: ApplyOperation
    let diffOperation: DiffOperation
    let recheckOperation: RecheckOperation
    var operationID: UUID?
    var operationTask: Task<Void, Never>?
    var backgroundCancel: (() -> Void)?
    let notifier: SyncStateNotifying
    let echoRegistrar: SyncWriteEchoRegistering
    let bodyWriteRegistration: SyncBodyWriteRegistration

    init(
        rowLoader: @escaping RowLoader,
        applyOperation: @escaping ApplyOperation,
        diffOperation: @escaping DiffOperation,
        recheckOperation: @escaping RecheckOperation,
        notifier: @escaping SyncStateNotifying = SyncStateNotifier.suppressed,
        echoRegistrar: @escaping SyncWriteEchoRegistering = SyncWriteEchoRegistrar.suppressed,
        bodyWriteRegistration: SyncBodyWriteRegistration = .suppressed,
        applyCoordinator: SkillUpdateApplyCoordinator? = nil
    ) {
        self.applyCoordinator = applyCoordinator ?? SkillUpdateApplyCoordinator()
        self.rowLoader = rowLoader
        self.applyOperation = applyOperation
        self.diffOperation = diffOperation
        self.recheckOperation = recheckOperation
        self.notifier = notifier
        self.echoRegistrar = echoRegistrar
        self.bodyWriteRegistration = bodyWriteRegistration
        self.applyCoordinator.observe(self)
    }

    var selectedCount: Int { selectedSkillIDs.count }
    var canApply: Bool {
        !isLoading && !isApplying && recheckingSkillID == nil && selectedCount > 0
    }

    func isSelected(_ row: UpdatesRow) -> Bool {
        selectedSkillIDs.contains(row.id)
    }

    func toggleSelection(_ row: UpdatesRow) {
        guard !isApplying, canSelect(row) else { return }
        if selectedSkillIDs.contains(row.id) {
            selectedSkillIDs.remove(row.id)
        } else {
            selectedSkillIDs.insert(row.id)
        }
    }

    func selectAll() {
        guard !isApplying else { return }
        selectedSkillIDs = Set(rows.filter(canSelect).map(\.id))
    }

    func selectNone() {
        guard !isApplying else { return }
        selectedSkillIDs.removeAll()
    }

    func setDriftConfirmation(_ confirmed: Bool, for row: UpdatesRow) {
        guard row.driftedLocally, !isApplying else { return }
        if confirmed {
            confirmedDriftSkillIDs.insert(row.id)
            statuses[row.id] = .idle
        } else {
            confirmedDriftSkillIDs.remove(row.id)
        }
    }

    func status(for row: UpdatesRow) -> UpdatesRowStatus {
        applyGate.isApplying(row.id) ? .updating : statuses[row.id] ?? .idle
    }

    func load(context: ModelContext) {
        guard !isLoading, !isApplyingBatch else { return }
        let id = beginOperation()
        isLoading = true
        let container = context.container
        operationTask = Task { await performLoad(container: container, operationID: id) }
    }

    func loadAndReport(context: ModelContext) async {
        guard !isLoading, !isApplyingBatch else { return }
        let id = beginOperation()
        isLoading = true
        await performLoad(container: context.container, operationID: id)
    }

    func applySelected(context: ModelContext) {
        guard canApply else { return }
        let id = beginOperation()
        isApplyingBatch = true
        let selected = rows.filter { selectedSkillIDs.contains($0.id) }
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
        isApplyingBatch = true
        let selected = rows.filter { selectedSkillIDs.contains($0.id) }
        await performApply(
            rows: selected,
            container: context.container,
            presentationContext: context,
            operationID: id
        )
    }

    func recheck(_ row: UpdatesRow, context: ModelContext) {
        guard !isApplying, recheckingSkillID == nil else { return }
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
        guard !isApplying, recheckingSkillID == nil else { return }
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
        invalidateEditorBody = { [weak library] in library?.noteEditorBodyInvalidated() }
        currentFolderRevisions = { [weak library] in library?.folderChangeRevisions ?? [:] }
        library.confirmLeavingAnyDraft { [weak self] proceed in
            guard let self, proceed else { return }
            self.reset()
            self.initialSelection = skillID.map { [$0] }
            self.isPresented = true
        }
    }

    func reset() {
        cancel()
        rows = []
        selectedSkillIDs = []
        confirmedDriftSkillIDs = []
        statuses = [:]
        initialSelection = nil
        isPresented = false
        loadError = nil
    }

    func cancel() {
        operationID = nil
        operationTask?.cancel()
        backgroundCancel?()
        operationTask = nil
        backgroundCancel = nil
        isLoading = false
        isApplyingBatch = false
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
