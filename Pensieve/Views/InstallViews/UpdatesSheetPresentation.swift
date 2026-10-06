import SwiftUI

/// The copy and control states consumed by the sheet; no file reads or operations run here.
struct UpdatesSheetPresentation {
    enum Content: Equatable {
        case loading
        case failed(String)
        case empty
        case rows
    }

    let title = "Skill Updates Available"
    let subtitle = "Review the changes before updating."
    let cancelTitle = "Cancel"
    let updateTitle = "Update"
    let retryTitle = "Retry"
    let loadingTitle = "Checking local copies…"
    let errorTitle = "Couldn't Load Updates"
    let emptyTitle = "No Updates Available"
    let emptyDescription = "Your checked GitHub skills are current."
    let content: Content
    let rows: [Row]
    let selectionLabel: String?
    let selectionSources: [Binding<Bool>]
    let selectionEnabled: Bool
    let cancelEnabled: Bool
    let updateEnabled: Bool
    let isApplying: Bool

    @MainActor
    init(_ model: UpdatesViewModel) {
        switch model.loadPhase {
        case .idle, .loading: content = .loading
        case let .failed(message): content = .failed(message)
        case .loaded: content = model.rows.isEmpty ? .empty : .rows
        }
        let selectableIDs = model.selectableSkillIDs
        rows = model.loadPhase == .loaded ? model.rows.map { Row($0, model: model, selectableIDs: selectableIDs) } : []
        let count = model.selectedCount
        selectionLabel = content == .rows ? "\(count) of \(selectableIDs.count) selected" : nil
        selectionEnabled = !model.isApplying && !selectableIDs.isEmpty
        selectionSources = model.selectableRows.map { row in
            Binding(get: { model.isSelected(row) },
                    set: { model.setSelection($0, for: row) })
        }
        cancelEnabled = !model.isApplying
        updateEnabled = model.canApply
        isApplying = model.isApplying
    }

    struct Row: Identifiable {
        let row: UpdatesRow
        var id: UUID { row.id }
        var name: String { row.skillName }
        var source: String { " — " + (row.repositoryDisplay.isEmpty ? "Source unavailable" : row.repositoryDisplay) }
        var commits: String { "\(row.shortInstalledCommit) → \(row.shortUpstreamCommit)" }
        let changesTitle = "View Changes"
        let replaceTitle = "Replace my local edits"
        let recheckTitle = "Re-check"
        let isSelected: Bool
        let selectionEnabled: Bool
        let changesEnabled: Bool
        let localEditsCopy: String?
        let replacementConfirmed: Bool
        let replacementEnabled: Bool
        let status: UpdatesRowStatus
        let showsRecheck: Bool
        let recheckEnabled: Bool

        var statusText: String? {
            switch status {
            case .idle: return nil
            case .confirmationRequired: return "Confirm the overwrite for this skill, then update again."
            case .updating: return "Updating…"
            case .updated: return "Updated"
            case let .failed(message, _): return message
            }
        }

        @MainActor
        init(_ row: UpdatesRow, model: UpdatesViewModel, selectableIDs: Set<UUID>) {
            self.row = row
            let selectable = selectableIDs.contains(row.id)
            isSelected = model.isSelected(row) && selectable
            selectionEnabled = !model.isApplying && selectable
            changesEnabled = selectable && !model.isApplying && model.recheckingSkillID == nil
            localEditsCopy = row.driftedLocally ? "You have local edits to this skill. Updating replaces them." : nil
            replacementConfirmed = model.confirmedDriftSkillIDs.contains(row.id)
            replacementEnabled = selectionEnabled && row.driftedLocally
            status = model.status(for: row)
            if case let .failed(_, offersRecheck) = status { showsRecheck = offersRecheck } else { showsRecheck = false }
            recheckEnabled = !model.isApplying && model.recheckingSkillID == nil
        }
    }
}
