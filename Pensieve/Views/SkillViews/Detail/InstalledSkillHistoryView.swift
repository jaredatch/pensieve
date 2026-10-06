import SwiftUI

/// The origin repository's timeline for a linked skill. It consumes the session owner's held values only;
/// remote author, subject, path, and file text are rendered through `Text` and `LineDiffView`.
struct InstalledSkillHistoryView: View {
    let skill: Skill
    let currentBody: String
    let origin: InstalledOrigin
    let updateAvailable: Bool
    let localRevision: UpstreamHistoryLocalRevision
    let onOpenUpdates: () -> Void
    let onUpdateCheck: UpstreamHistoryViewModel.UpdateCheckRequest
    @Bindable var history: UpstreamHistoryViewModel
    var hostedSession: InstalledSkillHistorySession? = Optional.none

    @State private var ownedSession = InstalledSkillHistorySession()
    @State private var nextRequestIntent = UpstreamHistoryViewModel.RequestIntent.appearance
    @State private var observedManualCheck: (skillID: UUID, count: UInt64)?

    private var session: InstalledSkillHistorySession { hostedSession ?? ownedSession }

    private var requestID: InstalledSkillHistoryPresentation.RequestID {
        InstalledSkillHistoryPresentation.RequestID(
            skill: skill,
            localRevision: localRevision,
            windowCount: session.requestedWindow,
            manualCheckCount: history.manualCheckCount(skillID: skill.id)
        )
    }

    private var content: InstalledSkillHistoryPresentation.Content {
        InstalledSkillHistoryPresentation.content(
            state: history.state,
            currentSkillID: history.currentSkillID,
            skillID: skill.id,
            origin: origin
        )
    }

    var body: some View {
        @Bindable var session = session
        VStack(alignment: .leading, spacing: 0) {
            switch content {
            case .loading:
                loadingRow
            case let .failed(message, installedSummary):
                failureRow(message, installedSummary: installedSummary)
            case let .loaded(result, isUpdating, failureMessage):
                if isUpdating { updatingRow }
                if let failureMessage { refreshFailureRow(failureMessage) }
                loadedTimeline(result)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, DesignTokens.historyContentTop)
        .padding(.bottom, Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: requestID) {
            let manualCheckCount = history.manualCheckCount(skillID: skill.id)
            let manualRetry = observedManualCheck.map {
                $0.skillID == skill.id && $0.count != manualCheckCount
            } ?? false
            observedManualCheck = (skill.id, manualCheckCount)
            let intent: UpstreamHistoryViewModel.RequestIntent = manualRetry ? .retry : nextRequestIntent
            nextRequestIntent = .mountedRefresh
            await requestHistory(intent: intent)
        }
        .onDisappear {
            nextRequestIntent = .appearance
            observedManualCheck = nil
        }
        .onChange(of: skill.id) { _, _ in resetPresentation() }
        .sheet(item: $session.diff) { presentation in
            UpstreamHistoryDiffSheet(
                sha: presentation.sha,
                versionBody: presentation.text,
                currentBody: currentBody,
                onClose: { session.diff = nil }
            )
        }
        .sheet(item: $session.edits) { presentation in
            LocalEditsDiffSheet(
                title: presentation.title,
                summary: presentation.summary,
                changes: presentation.changes,
                onClose: { session.edits = nil }
            )
        }
    }

    private var loadingRow: some View {
        HStack(spacing: Spacing.sm) {
            ProgressView().controlSize(.small)
            Text(InstalledSkillHistoryPresentation.loadingTitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, Spacing.sm)
    }

    private var updatingRow: some View {
        HStack(spacing: Spacing.sm) {
            ProgressView().controlSize(.small)
            Text(InstalledSkillHistoryPresentation.updatingTitle)
                .font(DesignTokens.historyRefreshNote)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, Spacing.sm)
    }

    private func refreshFailureRow(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.circle")
            Text(message)
            Button(InstalledSkillHistoryPresentation.tryAgainTitle) { Task { await requestHistory() } }
                .buttonStyle(.link)
        }
        .font(DesignTokens.historyRefreshNote)
        .foregroundStyle(.secondary)
        .padding(.bottom, Spacing.sm)
    }

    private func failureRow(_ message: String, installedSummary: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
            Text(installedSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(InstalledSkillHistoryPresentation.tryAgainTitle) { Task { await requestHistory() } }
                .controlSize(.large)
        }
        .padding(.vertical, Spacing.sm)
    }

    private func loadedTimeline(_ result: UpstreamHistoryResult) -> some View {
        InstalledHistoryLoadedTimeline(
            result: result,
            origin: origin,
            updateAvailable: updateAvailable,
            showAllReadRows: session.showAllReadRows,
            onOpenUpdates: onOpenUpdates,
            onViewDiff: presentDiff,
            onViewEdits: session.presentEdits,
            onShowOlder: session.showOlder
        )
    }

    private func presentDiff(_ row: InstalledSkillHistoryPresentation.UpstreamRow) {
        guard let text = InstalledSkillHistoryPresentation.text(row.history.skillMarkdown) else { return }
        session.diff = InstalledSkillHistorySession.UpstreamDiff(
            sha: row.history.sha,
            text: SkillHistoryPresentation.previewBody(from: text)
        )
    }

    private func requestHistory(intent: UpstreamHistoryViewModel.RequestIntent) async {
        let window = session.prepare(for: skill.id)
        await history.request(
            skill: skill,
            windowCount: window,
            localRevision: localRevision,
            intent: intent,
            onUpdateCheck: onUpdateCheck
        )
    }

    private func requestHistory() async {
        await requestHistory(intent: .retry)
    }

    private func resetPresentation() {
        session.reset(for: skill.id)
    }
}

private struct InstalledHistoryLoadedTimeline: View {
    let result: UpstreamHistoryResult
    let origin: InstalledOrigin
    let updateAvailable: Bool
    let showAllReadRows: Bool
    let onOpenUpdates: () -> Void
    let onViewDiff: (InstalledSkillHistoryPresentation.UpstreamRow) -> Void
    let onViewEdits: (InstalledSkillHistoryPresentation.LocalRow) -> Void
    let onShowOlder: (InstalledSkillHistoryPresentation.OlderAction, Int) -> Void

    private var shownCount: Int {
        InstalledSkillHistoryPresentation.shownCount(total: result.rows.count, showAllReadRows: showAllReadRows)
    }

    private var upstreamRows: [InstalledSkillHistoryPresentation.UpstreamRow] {
        InstalledSkillHistoryPresentation.upstreamRows(
            result: result,
            shownCount: shownCount,
            updateAvailable: updateAvailable
        )
    }

    private var local: InstalledSkillHistoryPresentation.LocalRow? {
        InstalledSkillHistoryPresentation.localRow(
            edits: result.localEdits,
            baseline: result.installedBaseline,
            installedCommit: origin.installedCommit
        )
    }

    private var note: String? {
        InstalledSkillHistoryPresentation.installedNote(
            position: result.installedPosition,
            commit: origin.installedCommit,
            ref: origin.ref
        )
    }

    var body: some View {
        timelineRows
        if let action = InstalledSkillHistoryPresentation.olderAction(
            total: result.rows.count,
            shown: shownCount,
            hasOlderHistory: result.hasOlderHistory
        ) {
            Button(InstalledSkillHistoryPresentation.showOlderTitle) {
                onShowOlder(action, result.windowCount)
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    @ViewBuilder private var timelineRows: some View {
        let rowCount = upstreamRows.count + (local == nil ? 0 : 1) + (note == nil ? 0 : 1)
        let upstreamOffset = local == nil ? 0 : 1
        if let local {
            SkillHistoryTimelineRow(dotColor: .orange, connectsUp: false, connectsDown: rowCount > 1) {
                localRow(local)
            }
        }
        ForEach(Array(upstreamRows.enumerated()), id: \.element.id) { offset, row in
            let rowIndex = offset + upstreamOffset
            SkillHistoryTimelineRow(
                dotColor: dotColor(row.badge),
                connectsUp: rowIndex > 0,
                connectsDown: rowIndex < rowCount - 1
            ) {
                upstreamRow(row)
            }
        }
        if let note {
            SkillHistoryTimelineRow(
                dotColor: Color(nsColor: .quaternaryLabelColor),
                connectsUp: upstreamRows.count + upstreamOffset > 0,
                connectsDown: false
            ) {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func localRow(_ row: InstalledSkillHistoryPresentation.LocalRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(InstalledSkillHistoryPresentation.localCaption)
                .font(.caption)
                .foregroundStyle(.orange)
            Text(row.title).font(.body)
            if let detailText = row.detailText {
                changeStats(
                    filesText: detailText,
                    additionsText: row.additionsText,
                    deletionsText: row.deletionsText,
                    accessibilityLabel: row.detail ?? detailText
                )
            }
            if row.canViewEdits {
                Button(InstalledSkillHistoryPresentation.viewEditsTitle) { onViewEdits(row) }
                    .controlSize(.large)
                    .padding(.top, 6)
            }
        }
    }

    private func upstreamRow(_ row: InstalledSkillHistoryPresentation.UpstreamRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Spacing.sm) {
                Text(row.shortHash).font(.system(size: 12, design: .monospaced))
                Text(row.date + " · " + row.history.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let badge = row.badge { historyBadge(badge) }
            }
            Text(row.history.subject).font(.body)
            changeStats(
                filesText: row.filesText,
                additionsText: row.additionsText,
                deletionsText: row.deletionsText,
                accessibilityLabel: row.stats
            )
            if row.canViewDiff || row.canUpdate {
                HStack(spacing: Spacing.sm) {
                    if row.canViewDiff {
                        Button(InstalledSkillHistoryPresentation.viewDiffTitle) { onViewDiff(row) }
                            .controlSize(.large)
                    }
                    if row.canUpdate {
                        Button(InstalledSkillHistoryPresentation.updateTitle, action: onOpenUpdates)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private func changeStats(
        filesText: String,
        additionsText: String?,
        deletionsText: String?,
        accessibilityLabel: String
    ) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(additionsText == nil ? filesText : filesText + " ·")
                .foregroundStyle(.secondary)
            if let additionsText, let deletionsText {
                Text(additionsText).foregroundStyle(Color.green)
                Text(deletionsText).foregroundStyle(Color.red)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func historyBadge(_ badge: InstalledSkillHistoryPresentation.Badge) -> some View {
        let isInstalled = badge == .installed
        return Text(isInstalled ? "Installed" : "Available")
            .font(.caption)
            .foregroundStyle(isInstalled ? Color.green : Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((isInstalled ? Color.green : Color.accentColor).opacity(0.1), in: Capsule())
    }

    private func dotColor(_ badge: InstalledSkillHistoryPresentation.Badge?) -> Color {
        switch badge {
        case .available: Color.accentColor
        case .installed: Color.green
        case nil: Color(nsColor: .quaternaryLabelColor)
        }
    }
}
