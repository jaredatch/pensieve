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
    var isLoading = false
    var hasLoadedRows = false
    var isApplying = false
    var recheckingSkillID: UUID?
    var isPresented = false
    var initialSelection: Set<UUID>?
    var loadError: String?

    let rowLoader: RowLoader
    let applyOperation: ApplyOperation
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

    var selectedCount: Int { selectedSkillIDs.count }
    var canApply: Bool {
        !isLoading && !isApplying && recheckingSkillID == nil && selectedCount > 0
    }

    func isSelected(_ row: UpdatesRow) -> Bool {
        selectedSkillIDs.contains(row.id)
    }

    func toggleSelection(_ row: UpdatesRow) {
        guard !isApplying else { return }
        if selectedSkillIDs.contains(row.id) {
            selectedSkillIDs.remove(row.id)
        } else {
            selectedSkillIDs.insert(row.id)
        }
    }

    func selectAll() {
        guard !isApplying else { return }
        selectedSkillIDs = Set(rows.map(\.id))
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
        statuses[row.id] ?? .idle
    }

    func load(context: ModelContext) {
        guard !isLoading, !isApplying else { return }
        let id = beginOperation()
        isLoading = true
        let container = context.container
        operationTask = Task { await performLoad(container: container, operationID: id) }
    }

    func loadAndReport(context: ModelContext) async {
        guard !isLoading, !isApplying else { return }
        let id = beginOperation()
        isLoading = true
        await performLoad(container: context.container, operationID: id)
    }

    func applySelected(context: ModelContext) {
        guard canApply else { return }
        let id = beginOperation()
        isApplying = true
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
        isApplying = true
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
        if isPresented {
            guard !isApplying, let skillID else { return }
            if isLoading || !hasLoadedRows || loadError != nil {
                // nil means the sheet was opened with all rows selected.
                if initialSelection != nil { initialSelection?.insert(skillID) }
                return
            }
            guard rows.contains(where: { $0.id == skillID }) else { return }
            selectedSkillIDs.insert(skillID)
            return
        }
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
        hasLoadedRows = false
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
