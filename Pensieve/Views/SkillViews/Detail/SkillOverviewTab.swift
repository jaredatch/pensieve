import SwiftUI

/// The stat strip, the Source table, and the Contents list. Every value comes from the snapshot and the
/// provenance; no disk read happens here.
struct SkillOverviewTab: View {
    let skill: Skill
    let snapshot: DetailContentSnapshot
    let provenance: SkillProvenance?
    let installedCount: Int
    let now: Date
    let homeDirectory: String
    let skillsDirectory: String
    @State private var showsAllFiles = false

    var body: some View {
        let stats = SkillOverviewPresentation.stats(snapshot: snapshot, installedCount: installedCount,
                                                    budgets: PlatformTokenBudgetSetting.values())
        let source = SkillOverviewPresentation.sourceRows(
            skill: skill, provenance: provenance, origin: skill.installedOrigin,
            homeDirectory: homeDirectory, skillsDirectory: skillsDirectory, now: now)
        let contents = SkillOverviewPresentation.contentsRows(inventory: snapshot.inventory)
        let shown = showsAllFiles ? contents : Array(contents.prefix(SkillOverviewPresentation.contentsRowsShown))

        VStack(alignment: .leading, spacing: Spacing.xxl) {
            HStack(alignment: .top, spacing: Spacing.xxl) {
                ForEach(stats) { StatCard(stat: $0) }
            }
            .fixedSize(horizontal: false, vertical: true)   // every card as tall as the tallest
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Source")
                    .font(DesignTokens.sectionHeading)
                    .foregroundStyle(.primary)
                VStack(spacing: 0) {
                    ForEach(source) { SourceRowView(row: $0) }
                }
            }
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Contents")
                        .font(DesignTokens.sectionHeading)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("tokens per file").font(.caption).foregroundStyle(.tertiary)
                }
                ForEach(shown) { ContentsRowView(row: $0) }
                if let more = SkillOverviewPresentation.moreFilesLabel(total: contents.count, shown: shown.count) {
                    Button(more) { showsAllFiles = true }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, DesignTokens.stripHairlineToContentTop)
        .padding(.bottom, Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: skill.id) { _, _ in showsAllFiles = false }
    }
}

/// The master `Stat column` (188 × 75): fill 3 %, corners 10, padding 10, label / value / sub on a 2 pt gap.
/// Three cards share the width and the tallest one's height, so at the window's 900 pt minimum they narrow together.
private struct StatCard: View {
    let stat: SkillOverviewPresentation.Stat

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.cardContentGap) {
            Text(stat.label)
                .font(DesignTokens.statLabel)
                .foregroundStyle(.primary)
            Text(stat.value)
                .font(DesignTokens.statValue)
                .foregroundStyle(.primary)
                .monospacedDigit()
            if let warning = stat.budgetWarning {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(warning == .exceeded ? Color.red : Color.yellow)
                        .accessibilityHidden(true)
                    Text(stat.detail)
                        .foregroundStyle(warning == .exceeded ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                }
                .font(DesignTokens.statSub)
            } else {
                Text(stat.detail)
                    .font(DesignTokens.statSub)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(DesignTokens.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            DesignTokens.cardFill,
            in: RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(stat.accessibilityLabel)
    }
}

/// The master `Key-value row` (612 × 29): a separator, then a 28 pt line — the label in a 96 pt column,
/// the value, the lighter detail, the trailing glyph.
private struct SourceRowView: View {
    let row: SkillOverviewPresentation.SourceRow

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(DesignTokens.kvSeparator)
                .frame(height: 1)
            HStack(spacing: Spacing.md) {
                Text(row.label)
                    .font(DesignTokens.kvLabel)
                    .foregroundStyle(.secondary)
                    .frame(width: DesignTokens.kvValueColumnStart - Spacing.md, alignment: .leading)
                HStack(spacing: Spacing.xs) {
                    Text(row.value).font(.body).textSelection(.enabled)
                    if let detail = row.detail {
                        Text(row.separator).font(.body).foregroundStyle(.tertiary)
                        Text(detail).font(.body).foregroundStyle(.tertiary).textSelection(.enabled)
                    }
                }
                .lineLimit(1)
                .truncationMode(.middle)
                Spacer(minLength: 0)
                if let action = row.action {
                    SourceRowAction(action: action)
                }
            }
            .frame(height: 28)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SourceRowAction: View {
    let action: SkillOverviewPresentation.SourceAction

    var body: some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(DesignTokens.kvGlyph)
                .foregroundStyle(.secondary)
                .frame(width: DesignTokens.kvGlyphWidth, height: DesignTokens.kvGlyphWidth)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var symbol: String {
        switch action {
        case .open: "arrow.up.forward.square"
        case .copy: "doc.on.doc"
        case .reveal: "folder"
        }
    }

    private var help: String {
        switch action {
        case .open: "Open on GitHub"
        case .copy: "Copy Commit"
        case .reveal: "Reveal in Finder"
        }
    }

    private func perform() {
        switch action {
        case .open(let url):
            NSWorkspace.shared.open(url)
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .reveal(let path):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }
}

/// The master `Contents row` (612 × 24): the file in mono in a 200 pt column, the 4 pt bar (the widest row
/// in the accent color, the rest gray) whose width is the row's share, the count in a 56 pt column. The
/// track fills the space between the two columns, so the count stays under `tokens per file` at any column
/// width (#4; the frame's 324 is that space at its 612).
struct ContentsRowView: View {
    let row: SkillOverviewPresentation.ContentsRow

    var body: some View {
        HStack(spacing: Spacing.lg) {
            Text(row.relativePath)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 200, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: DesignTokens.barCornerRadius)
                        .fill(DesignTokens.barTrack)
                    RoundedRectangle(cornerRadius: DesignTokens.barCornerRadius)
                        .fill(row.share >= 1
                              ? AnyShapeStyle(Color.accentColor)
                              : AnyShapeStyle(DesignTokens.barFill))
                        .frame(width: max(2, proxy.size.width * row.share))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: DesignTokens.barHeight)
            Text(row.tokens.formatted())
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
        }
        .frame(height: 24)
        .accessibilityElement(children: .combine)
    }
}
